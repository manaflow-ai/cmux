import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextWakeups
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
    /// The origin of the chief conversation tab's creation key; the
    /// `mutation_id` comes from `chiefTabKey` (one per creation).
    static let tabOrigin = "cmux-next-home"

    /// The home workspace in the local store, once the store reported it:
    /// the one `ensure_home` named, else the one the tree marks `home` (a
    /// reconnect or a window that opened before `ensure_home` answered).
    var homeWorkspace: WorkspaceModel? {
        guard let services else { return nil }
        let workspaces = services.machines.local.store.workspaces
        if let id = homeWorkspaceID, let named = workspaces.first(where: { $0.resourceID == id }) { return named }
        return workspaces.first { $0.kind == "home" }
    }

    /// Asks the store for its home workspace, then gives it the chief tab.
    func ensureHomeWorkspace(_ connection: DaemonConnection) {
        homeWorkspaceTask?.cancel()
        homeWorkspaceStep = "ensure_home"
        let generation = beginHomeEnsure()
        // task-owner: one ensure_home, then at most one conversation create and one tab create
        homeWorkspaceTask = Task { [weak self] in
            do {
                let home = try await HomeWorkspaceClient(connection).ensureHome()
                // Cancelled: the newer ensure_home owns the in-flight flag.
                guard let self, !Task.isCancelled, let services = self.services else { return }
                homeWorkspaceID = home
                settleHomeEnsure(generation)
                homeWorkspaceStep = await (HomeDock.classic ? "ensured \(home)" : dock.ensure(connection, store: services.machines.local.store, home: home,
                                                                                                   work: services.mainWork) {
                    TabMoves.toNewDockColumn($0, anchor: $1, edge: .left, role: .agentChat, respawn: $2, pinned: $3, services: services,
                                             completion: $4) })
                try await ensureChiefTab(connection, home: home)
            } catch is CancellationError {
            } catch {
                self?.settleHomeEnsure(generation)
                self?.homeWorkspaceStep = "failed: \(String(describing: error))"
                self?.logger.error("home workspace: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A new `ensure_home` owns the in-flight flag from now; returns its generation.
    func beginHomeEnsure() -> Int {
        homeEnsureGeneration &+= 1
        homeEnsureInFlight = true
        return homeEnsureGeneration
    }

    /// `ensure_home` `generation` answered or failed: the flag clears and ``awaitHomeEnsured()`` resumes,
    /// only when no newer one started since.
    func settleHomeEnsure(_ generation: Int) {
        guard homeEnsureGeneration == generation else { return }
        homeEnsureInFlight = false
        homeEnsureWaiters.settle(Self.homeEnsureSlot, with: false)
    }

    /// The longest ``awaitHomeEnsured()`` waits. `ensure_home` has the connection's request deadline,
    /// so its answer or failure ends the wait well before this.
    static let homeEnsuredWait: Duration = .seconds(30)
    /// The one slot of ``homeEnsureWaiters``: the latest `ensure_home` answered.
    static let homeEnsureSlot = "ensure_home"

    /// Returns once no `ensure_home` is in flight (at once when none is): a keyed wait settled when
    /// the latest one answers (``settleHomeEnsure(_:)``), never an observation.
    func awaitHomeEnsured() async {
        _ = await homeEnsureWaiters.value(of: Self.homeEnsureSlot, now: homeEnsureInFlight, timeout: Self.homeEnsuredWait) { inFlight in
            inFlight ? nil : true
        }
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

    /// The signed-in user's cloud Chiefs (the Hosted Chief, made when this
    /// service runs Cloud Chief brains, and the placed one), or none: signed
    /// out, or the read failed (logged; the last read stays). Unread (nil) until Cloud started: a launch-time
    /// ensure builds no feed and reads no token; ``cloudDidStart()`` reads them then.
    func readCloudChiefs() async -> HomeCloudChiefs? {
        guard let services else { return nil }
        guard services.cloudAuth.isSignedIn else { return HomeCloudChiefs() }
        guard services.cloudContext != nil else { return nil }
        let feed = services.feed
        do {
            // An unknown probe keeps the last read: a Hosted Chief never drops out of the tab on one failed request.
            guard let brains = await hostedChief.brainsAvailable() else { return nil }
            return try await HomeCloudChiefs.read(call: { path, body in try await Self.hostedCall(feed, path, body) }, hostedBrains: brains)
        } catch {
            logger.error("cloud chiefs: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Cloud started (`AppServices.startCloudNow`): the Chief tab is checked again with the cloud Chiefs read.
    func cloudDidStart() {
        guard let services else { return }
        guard services.cloudAuth.isSignedIn, let connection = services.machines.local.connection,
              services.machines.local.supports(DaemonCapability.workspaceKind.rawValue) else { return }
        ensureHomeWorkspace(connection)
    }

    /// Re-checks the Chief tab now (a chief was just placed on a server).
    func refreshChiefTab() {
        guard let services else { return }
        // The Chief moved to a server: that server's session joins the sidebar too.
        services.serverReach.refresh()
        guard let connection = services.machines.local.connection,
              services.machines.local.supports(DaemonCapability.workspaceKind.rawValue) else { return }
        ensureHomeWorkspace(connection)
    }

    private func ensureChiefTab(_ connection: DaemonConnection, home: ResourceID) async throws {
        guard let services else { return }
        let local = services.machines.local
        guard local.supports(DaemonCapability.conversationTabs.rawValue) else {
            homeWorkspaceStep = "no chief tab: the daemon lacks conversation tabs"
            return
        }
        // A cloud Chief answers in its cloud main conversation: the Hosted
        // Chief by default (the local history is copied into it), or the one
        // placed on a paired server when the user switched to it. A placed
        // chief without a Hosted Chief takes the tab only while the local
        // Chief has no history to hide (G6, one history).
        // The same sign-in also reads the Home list's Chiefs: the list hides an archived Chief's rows by them
        // (the page's own read can come before sign-in, and a docked Home never makes the page).
        if let read = await readCloudChiefs() { setCloudChiefs(read); await directory.refreshChiefs() }
        guard !Task.isCancelled else { return }
        // The local Chief keeps the tab until its history is in the Hosted Chief (``HostedChiefMigration/pending``).
        hostedChief.start(cloudChiefs.hosted)
        // The default Chief is this Mac's while its optchat-chief runs (HomeService+ChiefDefault).
        await refreshLocalChiefRunning()
        let cloud = tabChiefs
        let shown = cloudChief
        // Local conversations live in the Chief home's owner, not this build's
        // daemon. Nothing waits for it here: the owner's first connection runs
        // this again (HomeService.start's owner observation), and then a local
        // Chief with history takes the tab back from a cloud Chief.
        let owner = self.connection
        if shown == nil, owner == nil {
            homeWorkspaceStep = "waiting for the chief owner \(self.chief.home.session)"
            return
        }
        var listedAll: [ConversationSummary] = []
        if let owner { listedAll = try await ConversationClient(owner).list() }
        let known = Set(listedAll.map(\.id))
        let listed = HomeChiefName.select(from: listedAll)
        // The local Chief is looked up (never created) while a cloud Chief has the tab.
        let localChief = if shown == nil, let owner { try await chiefConversation(owner) } else { listed?.id }
        let localHasHistory = shown == nil || (listed?.lastSeq ?? 0) > 0
        guard let chief = cloud.chiefTab(local: localChief, localHasHistory: localHasHistory, choice: hostedChief.choice,
                                         prefersLocal: prefersLocalChief), HomeDock.classic else { return }
        homeWorkspaceStep = "waiting for the home workspace in the tree"
        // The tree reports a just-created home after its event: a keyed store wait for it (this task is
        // cancelled by the next connection, which runs this again).
        let workspace = await local.store.waitForWorkspace(resource: home, timeout: Self.homeEnsuredWait)
        guard !Task.isCancelled, let workspace else { return }
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
        let others = [cloudChiefs.hosted?.mainConversation, cloudChiefs.placed?.mainConversation].compactMap { $0 }
        let move = HomeCloudChiefs.move(from: [localChief].compactMap { $0 } + others, chief: chief, in: local.store.workspaces)
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
        // The other cloud Chief's tab (a switch, or a relaunch put it in the Chief's place) goes.
        for surface in HomeCloudChiefs.staleChiefTabs(stale: others, chief: chief, in: local.store.workspaces) {
            try await connection.closeTab(surface)
        }
        homeWorkspaceStep = created ? (move.close.isEmpty ? "chief tab requested" : "chief tab moved to its server") : "chief tab present"
    }

    // MARK: Tab content

    /// The view of conversation tab `tab`, made on first show. Opening Home
    /// starts the local mux's brain host once per launch.
    func tabView(for tab: TabModel) -> HomeHostView? {
        guard let services else { return nil }
        guard tab.kind == .conversation, let conversation = tab.snapshot.conversation?.conversation else { return nil }
        if let view = tabViews[tab.id] { return view }
        let view = HomeHostView(services: services, conversation: conversation)
        tabViews[tab.id] = view
        // A cloud Chief's brain runs in the cloud or on its server: no local brain host for its tab.
        if cloudChiefs.chief(for: conversation) == nil { homeDidOpen(asked: true) }
        return view
    }

    func existingTabView(_ key: String) -> HomeHostView? { tabViews[key] }

    /// The strip title of conversation tab `tab`: its conversation's title.
    func tabTitle(for tab: TabModel) -> String {
        let id = tab.snapshot.conversation?.conversation
        // A Chief's one name (its record, or a rename being saved), as its tile and header show it.
        if let id, let name = chiefName(of: .init(id)) { return name }
        if let id, let chief = cloudChiefs.chief(for: id) {
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
