public import CmuxNextDaemon
import Foundation
import os

/// What ``WindowHomes`` needs of the app's windows and daemon: one-line forwards (`AppServices`).
@MainActor
public protocol WindowHomeHost: AnyObject {
    /// The store's home workspace, once the store reported it.
    var windowHomeStoreHome: WorkspaceModel? { get }
    /// The local daemon's connection and store.
    var windowHomeConnection: DaemonConnection? { get }
    var windowHomeStore: DaemonStore { get }
    /// Returns once the local store applied every event before `connection`'s last reply.
    func windowHomeApplied(_ connection: DaemonConnection) async
    /// The workspaces window `window` lists, and the open window that lists `workspace`.
    func windowHomeMembers(_ window: String) -> [String]
    func windowHomeOpenOwner(of workspace: String) -> String?
    func windowHomeWorkspace(_ id: String) -> WorkspaceModel?
    /// Shows `workspace` in window `window`, taking it there; never in another window.
    func windowHomeShow(_ workspace: String, in window: String)
    /// Claims the workspace about to be made for `window`, or drops that claim.
    func windowHomeClaim(_ workspace: String, window: String)
    func windowHomeDropClaim(_ workspace: String)
    /// Runs `create` with `workspace` held out of its window until its first tab shows.
    func windowHomeHold(_ workspace: String, _ create: () async throws -> Bool?) async throws
    /// The app's move of a tab into a new left chat dock (``HomeDock/Dock``).
    func windowHomeDock(_ tab: TabModel, _ anchor: PaneModel, _ respawn: SplitRespawn?, _ pinned: Bool,
                        _ done: @escaping @MainActor (Bool) -> Void)
}

/// Each window's own Home (cmux#27880). The store has one home workspace, and a workspace lives
/// in one window: Home clicked in a second window brought the first window forward with its Home,
/// and moving that Home over would have taken the first window's panes and tabs with it. A window
/// that does not hold the store's home gets a Home of its own the first time it shows Home: a
/// workspace holding Home's page tab in the pinned chat dock (``WorkspaceModel/isWindowHome``),
/// with an empty right column. Its page is the same Messages/Channels view over the one Home
/// service, so the Chief chat is shared; what opens beside it stays in that window.
@MainActor
public final class WindowHomes {
    /// The origin of a window Home's page tab creation key.
    static let origin = "cmux-next-window-home"
    private weak var host: (any WindowHomeHost)?
    /// Window Homes being made, by window id, so a second click joins the first.
    private var making: [String: Task<WorkspaceModel?, Never>] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    public init(host: any WindowHomeHost) { self.host = host }

    /// The Home window `window` shows: the store's home when the window holds it, else the
    /// window's own Home, else the store's home when no other open window holds it. Nil when
    /// another open window holds the store's home and this one has no Home yet.
    public func home(in window: String) -> WorkspaceModel? {
        guard let host else { return nil }
        let store = host.windowHomeStoreHome
        let members = host.windowHomeMembers(window)
        if let store, members.contains(store.id) { return store }
        if let own = members.lazy.compactMap({ host.windowHomeWorkspace($0) }).first(where: \.isWindowHome) { return own }
        guard let store, let owner = host.windowHomeOpenOwner(of: store.id) else { return store }
        return owner == window ? store : nil
    }

    /// Shows window `window`'s Home in that window, making it first when it has none. Never acts
    /// in another window. Returns the Home once it is in the store (nil: it could not be made).
    @discardableResult
    public func show(in window: String) async -> WorkspaceModel? {
        if let home = home(in: window) {
            host?.windowHomeShow(home.id, in: window)
            return home
        }
        if let pending = making[window] { return await pending.value }
        // task-owner: one window Home creation per window (joined by later clicks), bounded by the daemon replies
        let task = Task { @MainActor [weak self] () -> WorkspaceModel? in
            defer { self?.making[window] = nil }
            return await self?.make(in: window)
        }
        making[window] = task
        return await task.value
    }

    /// One window Home: the workspace and its page tab, held out of the window until the page is
    /// there, so the window shows it in one step with no workspace row; then the page goes into
    /// the pinned chat dock as the store's Home does (``HomeDock/ensure``).
    private func make(in window: String) async -> WorkspaceModel? {
        guard let host, let connection = host.windowHomeConnection else { return nil }
        let store = host.windowHomeStore
        let key = WorkspaceKey.generate()
        // Claimed first, so the reconcile that places it puts it in this window and selects it there.
        host.windowHomeClaim(key.rawValue, window: window)
        do {
            try await host.windowHomeHold(key.rawValue) {
                try await connection.createWorkspace(name: HomeStrings.title, key: key)
                await host.windowHomeApplied(connection)
                guard let workspace = store.workspace(id: key.rawValue) else { return nil }
                _ = try await connection.request(NewConversationTabRequest(page: HomeDock.page, workspace: workspace.handle, origin: Self.origin,
                                                                           mutationID: UUID().uuidString.lowercased()))
                return true
            }
        } catch {
            logger.error("window home: \(String(describing: error), privacy: .public)")
            host.windowHomeDropClaim(key.rawValue)
            return nil
        }
        guard let home = host.windowHomeWorkspace(key.rawValue) else { return nil }
        if let resource = home.resourceID {
            let step = await HomeDock().ensure(connection, store: store, home: resource, dock: { host.windowHomeDock($0, $1, $2, $3, $4) })
            logger.info("window home \(key.rawValue, privacy: .public): \(step, privacy: .public)")
        }
        return home
    }
}
