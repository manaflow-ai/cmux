import CmuxNextDaemon
import Foundation

/// Home as a workspace (plans/cmux-next/home.md 7): the store owns one home
/// workspace (`workspace-kind-v1`), and its content is a conversation tab
/// (`conversation-tabs-v1`) showing the chief conversation with the mux.
/// The app only asks: `workspace.ensure_home` on every connect, then one
/// keyed `new-conversation-tab` when the home has no chief tab. Both are
/// idempotent in the store, so two windows or a reconnect never duplicate.
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

    /// The chief conversation: the first local conversation with the mux,
    /// else one created under a fixed key.
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

    private func ensureChiefTab(_ connection: DaemonConnection, home: ResourceID) async throws {
        let local = services.machines.local
        guard local.supports(DaemonCapabilities.shared.conversationTabs),
              local.supports(DaemonCapabilities.shared.localConversations) else {
            homeWorkspaceStep = "no chief tab: the daemon lacks conversation tabs or local conversations"
            return
        }
        let chief = try await chiefConversation(connection)
        homeWorkspaceStep = "waiting for the home workspace in the tree"
        // The tree reports a just-created home after its event; wait for it
        // (this task is cancelled by the next connection).
        var found: WorkspaceModel?
        for await workspace in Observations({ local.store.workspaces.first { $0.resourceID == home } }) {
            if let workspace { found = workspace; break }
        }
        guard !Task.isCancelled, let workspace = found else { return }
        // The chief tab anywhere in the local tree counts (moved out of the home too).
        let open = HomeChiefTabKey.isOpen(chief: chief, in: local.store.workspaces)
        // A pane when the home has one. An empty home needs `workspace`, which
        // daemons with the raw `Workspace.kind` field accept; an older one
        // would put the tab in the focused pane, so it waits for that pin.
        let pane = workspace.screens.first?.panes.first?.handle
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
        homeWorkspaceStep = created ? "chief tab requested" : "chief tab present"
    }

    // MARK: Tab content

    /// The view of conversation tab `tab`, made on first show. Opening Home
    /// starts the local mux's brain host once per launch.
    func tabView(for tab: TabModel) -> HomeHostView? {
        guard tab.kind == .conversation, let conversation = tab.snapshot.conversation?.conversation else { return nil }
        if let view = tabViews[tab.id] { return view }
        let view = HomeHostView(services: services, conversation: conversation)
        tabViews[tab.id] = view
        homeDidOpen()
        return view
    }

    func existingTabView(_ key: String) -> HomeHostView? { tabViews[key] }

    /// The strip title of conversation tab `tab`: its conversation's title.
    func tabTitle(for tab: TabModel) -> String {
        let id = tab.snapshot.conversation?.conversation
        let title = conversations.first { $0.id == id }?.title ?? ""
        return title.isEmpty ? HomeStrings.title : title
    }

    /// The tab closed: its view goes with it.
    func releaseTabView(_ key: String) {
        tabViews.removeValue(forKey: key)
    }
}
