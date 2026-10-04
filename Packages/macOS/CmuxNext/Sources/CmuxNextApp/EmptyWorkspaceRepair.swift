import CmuxNextDaemon
import Foundation
import os

/// The one owner of what happens to a workspace with no pane.
///
/// A workspace whose last tab closed (Cmd-W, the tab's x, the CLI, or the
/// process exiting) closes: this connection saw it with a pane, then without
/// one (dogfood nxdog9, REWRITE.md round 3). The window rule then closes a
/// window that held only that workspace (`WindowRegistry`).
///
/// A workspace that is empty the first time this connection sees it gets
/// one terminal instead. That is the only case the repair exists for: after
/// a hard daemon kill the restarted daemon can report workspaces with no
/// screens, and another client (plain `cmux-tui`) can create a workspace
/// without a terminal. What was seen counts only on the connection it was
/// seen on (`DaemonStore.connectionEpoch`), so after a daemon restart an
/// empty workspace is repaired, not closed.
///
/// Two paths create a workspace's first terminal: this app populating a
/// workspace it just created (create-workspace, then create-terminal), and
/// the repair. Both answer before their pane delta reaches the mirror, and
/// meanwhile the workspace still looks empty. Each workspace therefore has a
/// `FirstTerminal` state here from the moment either path starts until the
/// store reports the workspace populated, and a workspace with a state is
/// never repaired or closed. A failed request releases it; the next store
/// change retries.
///
/// Process-wide per daemon, so two windows showing the same workspace send
/// one command, and a workspace no window shows closes too.
@MainActor
final class EmptyWorkspaceRepair {
    /// Who is giving a workspace its first terminal.
    enum FirstTerminal: Equatable {
        /// This app is running create-workspace + create-terminal
        /// (`populating`); the count of nested callers.
        case populating(Int)
        /// A create-terminal was sent (a repair) or answered (either path);
        /// waiting for the store to show a pane.
        case awaitingPane
        /// This app is moving every tab out of the workspace and closes it
        /// afterwards (a tab drag), or its last tab closed and it is being
        /// closed: it is empty on purpose, never repaired.
        case closing
    }

    /// Creates the first terminal of `key` (`create-terminal`, which adds the
    /// first screen and pane). Returns the new surface. Tests replace it.
    var create: @MainActor (WorkspaceKey) async throws -> SurfaceID?
    /// Closes `key`, a workspace whose last tab closed. Tests replace it.
    var close: @MainActor (WorkspaceKey) async throws -> Void = { _ in }
    /// Why `key` lost its last pane. Tests replace it.
    var cause: @MainActor (WorkspaceKey) async -> EmptiedWorkspaceCause
    /// Whether commands can run now. Tests replace it.
    var canCreate: @MainActor () -> Bool
    private(set) var states: [WorkspaceKey: FirstTerminal] = [:]
    /// The last emptied workspaces and what this app did with each (closed,
    /// or kept with a new terminal), newest last, for `debug.windows`: a
    /// workspace that disappears is always explained.
    private(set) var decisions: [(key: WorkspaceKey, cause: EmptiedWorkspaceCause)] = []
    /// Workspaces seen with a pane, with the connection epoch they were seen
    /// on: one seen on the current connection that has no pane now had its
    /// last tab closed.
    private var populated: [WorkspaceKey: Int] = [:]
    /// The daemon store's connection epoch. Tests replace it.
    var epoch: @MainActor () -> Int
    /// Whether the store holds a live snapshot. The launch snapshot's
    /// provisional tree was not seen on any connection, so a workspace it
    /// shows with a pane must not count as emptied when the live tree shows
    /// it without one (the daemon restarted without its terminals): that one
    /// is repaired. Tests replace it.
    var isLive: @MainActor () -> Bool
    private var observation: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.empty-workspace")

    init(daemon: DaemonService) {
        create = { [weak daemon] key in
            guard let daemon, let connection = daemon.connection else { throw DaemonError.notConnected }
            let cwd = daemon.defaultCwd
            return try await connection.createTerminal(in: key, cwd: cwd).surface
        }
        canCreate = { [weak daemon] in
            guard let daemon, daemon.store.isLoaded else { return false }
            if case .connected = daemon.store.connectionState { return true }
            return false
        }
        epoch = { [weak daemon] in daemon?.store.connectionEpoch ?? 0 }
        isLive = { [weak daemon] in daemon?.store.isLoaded ?? false }
        cause = { [weak daemon] key in
            // When the registry cannot be read, keep the workspace: a
            // needless repair costs one terminal, a needless close loses
            // the user's workspace.
            guard let connection = daemon?.connection, let terminals = try? await connection.listTerminals() else { return .terminalLost }
            return EmptiedWorkspaceCause.from(terminals, workspace: key)
        }
        close = { [weak daemon] key in
            guard let daemon, let connection = daemon.connection else { throw DaemonError.notConnected }
            // No tab is left, so no terminal to end here.
            try await WorkspaceClose.close(key, terminals: [], on: connection)
        }
        observe(daemon.store)
    }

    isolated deinit {
        observation?.cancel()
    }

    /// Every workspace, shown or not: which have a pane, and the connection.
    private func observe(_ store: DaemonStore) {
        observation = Task { [weak self, weak store] in
            for await _ in Observations({ () -> [String] in
                guard let store else { return [] }
                // Turning live counts as a change: a tree drawn from the
                // launch snapshot is first seen on a connection then.
                return ["live:\(store.isLoaded)"] + store.workspaces.map { "\($0.key?.rawValue ?? ""):\(Self.hasPane($0))" }
            }) {
                guard let self, let store else { return }
                self.storeDidChange(store)
            }
        }
    }

    private func storeDidChange(_ store: DaemonStore) {
        guard isLive() else { return }
        for workspace in store.workspaces where !Self.isHome(workspace) {
            guard let key = workspace.key else { continue }
            if Self.hasPane(workspace) { notePopulated(key) } else { closeIfEmptied(key) }
        }
        let present = Set(store.workspaces.compactMap(\.key))
        populated = populated.filter { present.contains($0.key) }
        for key in states.keys where !present.contains(key) && states[key] == .closing { states[key] = nil }
    }

    /// The store's home workspace (workspace-kind-v1) starts empty on
    /// purpose and the daemon never closes it: HomeService owns its content
    /// (the Chief conversation tab), so it is neither repaired nor closed.
    private static func isHome(_ workspace: WorkspaceModel) -> Bool {
        workspace.kind == "home"
    }

    private static func hasPane(_ workspace: WorkspaceModel) -> Bool {
        !workspace.screens.allSatisfy(\.panes.isEmpty)
    }

    private func notePopulated(_ key: WorkspaceKey) {
        populated[key] = epoch()
        // Whoever created the terminal is done, unless this app is still
        // inside its own populate call or closing it.
        if states[key] == .awaitingPane { states[key] = nil }
    }

    /// Closes `key` when this connection saw it with a pane and nothing
    /// else owns it. Returns whether `key` is (being) closed.
    @discardableResult
    private func closeIfEmptied(_ key: WorkspaceKey) -> Bool {
        guard populated[key] == epoch(), states[key] == nil, canCreate() else { return states[key] == .closing }
        states[key] = .closing
        populated[key] = nil
        let close = close, cause = cause, create = create
        // task-owner: one decision per emptied workspace; the claim is the state above
        Task {
            // A lost terminal (its host died: crash, kill, reboot) is not a
            // closed tab: the workspace stays and gets a new terminal.
            if await cause(key) == .terminalLost {
                guard states[key] == .closing else { return }
                states[key] = .awaitingPane
                record(key, .terminalLost)
                logger.info("workspace \(key.rawValue, privacy: .public) lost its last terminal; keeping it with a new terminal")
                do {
                    _ = try await create(key)
                } catch {
                    if states[key] == .awaitingPane { states[key] = nil }
                    logger.error("refilling a workspace with a lost terminal failed: \(String(describing: error), privacy: .public)")
                }
                return
            }
            record(key, .tabClosed)
            logger.info("workspace \(key.rawValue, privacy: .public) lost its last tab; closing it")
            do {
                try await close(key)
            } catch {
                // Still open and empty: the next change repairs it instead.
                if states[key] == .closing { states[key] = nil }
                logger.error("closing emptied workspace failed: \(String(describing: error), privacy: .public)")
            }
        }
        return true
    }

    private func record(_ key: WorkspaceKey, _ cause: EmptiedWorkspaceCause) {
        decisions.append((key, cause))
        if decisions.count > 32 { decisions.removeFirst(decisions.count - 32) }
    }

    /// Checks `workspace` (shown in a window) after a store change. An
    /// emptied workspace closes; one empty since this connection first saw
    /// it gets one create-terminal, and `created` gets the new surface.
    func check(_ workspace: WorkspaceModel, created: @escaping @MainActor (SurfaceID) -> Void) {
        guard let key = workspace.key, isLive(), !Self.isHome(workspace) else { return }
        guard !Self.hasPane(workspace) else { return notePopulated(key) }
        guard states[key] == nil, !closeIfEmptied(key), canCreate() else { return }
        states[key] = .awaitingPane
        logger.info("workspace \(key.rawValue, privacy: .public) has no pane; creating a terminal")
        let create = create
        // task-owner: one request per claimed workspace; the claim is the state above
        Task {
            do {
                if let surface = try await create(key) { created(surface) }
            } catch {
                if states[key] == .awaitingPane { states[key] = nil }
                logger.error("empty workspace repair failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `key` is emptied on purpose (its tabs are moving to another
    /// workspace) and will close: no repair until `endClosing`.
    func beginClosing(_ key: WorkspaceKey) { states[key] = .closing }

    /// The move failed (the tabs stayed): repairs apply again.
    func endClosing(_ key: WorkspaceKey) {
        if states[key] == .closing { states[key] = nil }
    }

    /// Marks `key` as being populated by this app for the duration of
    /// `body` (create-workspace then create-terminal). On success the
    /// workspace stays owned until the store shows its pane, because
    /// `body` returns with the create-terminal reply, before the delta.
    func populating<T>(_ key: WorkspaceKey, _ body: () async throws -> T) async rethrows -> T {
        if case .populating(let count) = states[key] { states[key] = .populating(count + 1) } else { states[key] = .populating(1) }
        do {
            let value = try await body()
            finishPopulating(key, succeeded: true)
            return value
        } catch {
            finishPopulating(key, succeeded: false)
            throw error
        }
    }

    private func finishPopulating(_ key: WorkspaceKey, succeeded: Bool) {
        guard case .populating(let count) = states[key] else { return }
        if count > 1 {
            states[key] = .populating(count - 1)
        } else {
            states[key] = succeeded ? .awaitingPane : nil
        }
    }
}
