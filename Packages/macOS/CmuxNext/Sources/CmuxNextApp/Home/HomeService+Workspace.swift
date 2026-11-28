import CmuxNextDaemon
import Foundation

/// Home as a workspace (plans/cmux-next/home.md 7): the store owns one home
/// workspace (`workspace-kind-v1`), and its content is a conversation tab
/// (`conversation-tabs-v1`) showing the chief conversation with the mux, or
/// with the chief placed on a paired server when the user has one (G6).
/// The app only asks: `workspace.ensure_home` on every connect, then one
/// keyed `new-conversation-tab` when the home has no chief tab. Both are
/// idempotent in the store, so two windows or a reconnect never duplicate.
/// The workspace and its tabs live in this build's daemon; the chief
/// conversation lives in the Chief home's owner (`ChiefConversationOwner`),
/// so the tab names a conversation of that owner.
extension HomeService {
    /// The idempotency key of the chief conversation's creation.
    static let chiefKey = HomeChiefName.createKey
    /// The origin of the chief conversation tab's creation key; the
    /// `mutation_id` comes from `chiefTabKey` (one per creation).
    static let tabOrigin = "cmux-next-home"

    /// The home workspace in the local store, once the store reported it:
    /// the one `ensure_home` named, else the one the tree marks `home` (a
    /// reconnect or a window that opened before `ensure_home` answered).
    var homeWorkspace: WorkspaceModel? {
        let workspaces = services.machines.local.store.workspaces
        if let id = homeWorkspaceID, let named = workspaces.first(where: { $0.resourceID == id }) { return named }
        return workspaces.first { $0.kind == "home" }
    }

    /// Asks the store for its home workspace, then gives it the chief tab.
    func ensureHomeWorkspace(_ connection: DaemonConnection) {
        homeWorkspaceTask?.cancel()
        homeWorkspaceStep = "ensure_home"
        // task-owner: one ensure_home, then at most one conversation create and one tab create
        homeWorkspaceTask = Task { [weak self] in
            do {
                let home = try await HomeWorkspaceClient(connection).ensureHome()
                guard let self, !Task.isCancelled else { return }
                homeWorkspaceID = home
                homeWorkspaceStep = "ensured \(home)"
                try await ensureChiefTab(connection, home: home)
            } catch is CancellationError {
            } catch {
                self?.homeWorkspaceStep = "failed: \(String(describing: error))"
                self?.logger.error("home workspace: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The Chief owner's connection, once it serves conversations (this task
    /// is cancelled by the next local connection).
    private func chiefConnection() async -> DaemonConnection? {
        let chief = chief
        for await connection in Observations({ chief.supports(DaemonCapabilities.shared.localConversations) ? chief.connection : nil }) {
            if let connection { return connection }
        }
        return nil
    }

    /// The chief conversation: the oldest conversation with the mux in the
    /// Chief owner, else one created under a fixed key.
    private func chiefConversation(_ connection: DaemonConnection) async throws -> String {
        let client = ConversationClient(connection)
        if let existing = HomeChiefName.select(from: try await client.list()) {
            // One-time rename to the chief's name (N1); a failure keeps the old title.
            if let rename = HomeChiefName.migration(for: existing) {
                do { _ = try await client.op(rename) } catch {
                    logger.error("chief rename: \(String(describing: error), privacy: .public)")
                }
            }
            return existing.id
        }
        return try await client.create(HomeChiefName.createRequest(user: Self.localUser, mux: Self.mux)).conversation.id
    }

    /// The signed-in user's chief placed on a paired server (G6), or nil:
    /// signed out, none placed, or the read failed (logged; the local chief stays).
    func readPlacedChief() async -> CloudChief? {
        guard services.cloud.auth.isSignedIn, case let feed = services.feed else { return nil }
        do {
            return try await HomeChiefSource.readPlaced { path, body in try await feed.call(path, body) }
        } catch {
            logger.error("placed chief: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Re-checks the Chief tab now (a chief was just placed on a server).
    func refreshChiefTab() {
        // The Chief moved to a server: that server's session joins the sidebar too.
        services.serverReach.refresh()
        guard let connection = services.machines.local.connection,
              services.machines.local.supports(DaemonCapabilities.shared.workspaceKind) else { return }
        ensureHomeWorkspace(connection)
    }

    private func ensureChiefTab(_ connection: DaemonConnection, home: ResourceID) async throws {
        let local = services.machines.local
        guard local.supports(DaemonCapabilities.shared.conversationTabs) else {
            homeWorkspaceStep = "no chief tab: the daemon lacks conversation tabs"
            return
        }
        // The chief placed on a paired server answers in its cloud main
        // conversation; it is the Chief tab only while the local Chief has no
        // history to hide (G6, one history).
        let placed = await readPlacedChief()
        guard !Task.isCancelled else { return }
        setCloudChief(placed)
        // Local conversations live in the Chief home's owner, not this build's
        // daemon. A placed chief does not wait for it: its tab shows now, and
        // the owner's first connection runs this again (HomeService.start),
        // when a local Chief with history takes the tab back.
        let owner: DaemonConnection?
        if placed == nil {
            homeWorkspaceStep = "waiting for the chief owner \(self.chief.home.session)"
            owner = await chiefConnection()
            guard owner != nil, !Task.isCancelled else { return }
        } else {
            owner = chief.supports(DaemonCapabilities.shared.localConversations) ? chief.connection : nil
        }
        var listedAll: [ConversationSummary] = []
        if let owner { listedAll = try await ConversationClient(owner).list() }
        let known = Set(listedAll.map(\.id))
        let listed = HomeChiefName.select(from: listedAll)
        // The local Chief is looked up (never created) once a chief is placed.
        let localChief = if placed == nil, let owner { try await chiefConversation(owner) } else { listed?.id }
        let localHasHistory = placed == nil || (listed?.lastSeq ?? 0) > 0
        guard let chief = HomeChiefSource.choose(local: localChief, localHasHistory: localHasHistory, placed: placed) else { return }
        homeWorkspaceStep = "waiting for the home workspace in the tree"
        // The tree reports a just-created home after its event; wait for it
        // (this task is cancelled by the next connection).
        var found: WorkspaceModel?
        for await workspace in Observations({ local.store.workspaces.first { $0.resourceID == home } }) {
            if let workspace { found = workspace; break }
        }
        guard !Task.isCancelled, let workspace = found else { return }
        // A local conversation tab whose conversation the Chief owner does not
        // have shows nothing: a build's own Chief from before the Chief home.
        // Only the owner's own list can call a tab dangling.
        let dangling: [TabModel] = owner == nil ? [] : workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { tab in
            tab.kind == .conversation
                && tab.snapshot.conversation.map { ref in ref.owner == "local" && ref.conversation.map { !known.contains($0) } == true } == true
        }
        if !dangling.isEmpty {
            try await connection.closeTabs(dangling.map(\.surface), endTerminals: false)
        }
        // The chief tab anywhere in the local tree counts (moved out of the home too).
        let open = HomeChiefTabKey.isOpen(chief: chief, in: local.store.workspaces)
        // A pane when the home has one. An empty home needs `workspace`, which
        // daemons with the raw `Workspace.kind` field accept; an older one
        // would put the tab in the focused pane, so it waits for that pin.
        // The Chief moved to a server: one Chief tab, where the local one was.
        // After closing a dangling tab its pane may be gone: name the workspace.
        let move = HomeChiefSource.move(local: localChief, chief: chief, in: local.store.workspaces)
        let pane = move.pane ?? (dangling.isEmpty ? workspace.screens.first?.panes.first?.handle : nil)
        guard open || pane != nil || workspace.kind != nil else {
            homeWorkspaceStep = "no chief tab: an empty home on a daemon without Workspace.kind"
            return
        }
        // The key lives on the service (shared by overlapping connects); a
        // lost reply keeps it pending for the next connect.
        let created = try await chiefTabKey.ensure(chiefTabOpen: open) { mutationID in
            let request = NewConversationTabRequest(conversation: chief, pane: pane, workspace: pane == nil ? workspace.handle : nil,
                                                    origin: Self.tabOrigin, mutationID: mutationID)
            _ = try await connection.request(request)
        }
        for surface in move.close { try await connection.closeTab(surface) }
        // A placed chief's tab that a relaunch put in a local Chief's place goes.
        for surface in HomeChiefSource.staleChiefTabs(placed: placed?.mainConversation, chief: chief, in: local.store.workspaces) {
            try await connection.closeTab(surface)
        }
        homeWorkspaceStep = created ? (move.close.isEmpty ? "chief tab requested" : "chief tab moved to its server") : "chief tab present"
    }

    // MARK: Tab content

    /// The view of conversation tab `tab`, made on first show. Opening Home
    /// starts the local mux's brain host once per launch.
    func tabView(for tab: TabModel) -> HomeHostView? {
        guard tab.kind == .conversation, let conversation = tab.snapshot.conversation?.conversation else { return nil }
        if let view = tabViews[tab.id] { return view }
        let view = HomeHostView(services: services, conversation: conversation)
        tabViews[tab.id] = view
        // A placed chief's brain runs on its server: no local brain host for its tab.
        if conversation != cloudChief?.mainConversation { homeDidOpen() }
        return view
    }

    func existingTabView(_ key: String) -> HomeHostView? { tabViews[key] }

    /// The strip title of conversation tab `tab`: its conversation's title.
    func tabTitle(for tab: TabModel) -> String {
        let id = tab.snapshot.conversation?.conversation
        if let chief = cloudChief, id == chief.mainConversation {
            return chief.displayName.isEmpty ? HomeStrings.chiefName : chief.displayName
        }
        let title = conversations.first { $0.id == id }?.title ?? ""
        return title.isEmpty ? HomeStrings.title : title
    }

    /// The tab closed: its view goes with it.
    func releaseTabView(_ key: String) {
        tabViews.removeValue(forKey: key)
    }
}
