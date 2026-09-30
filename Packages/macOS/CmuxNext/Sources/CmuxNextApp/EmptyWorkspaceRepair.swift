import CmuxNextDaemon
import Foundation
import os

/// The one owner of "give this workspace its first terminal".
///
/// Two paths create a workspace's first terminal: this app populating a
/// workspace it just created (create-workspace, then create-terminal), and
/// the repair of a shown workspace with no panes (for example after a hard
/// daemon kill). Both answer before their pane delta reaches the mirror, and
/// meanwhile the workspace still looks empty. Each workspace therefore has a
/// `FirstTerminal` state here from the moment either path starts until the
/// store reports the workspace populated, and a workspace with a state is
/// never repaired. A failed request releases it; the next store change
/// retries.
///
/// Process-wide per daemon, so two windows showing the same workspace send
/// one command.
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
        /// afterwards (a tab drag): it is empty on purpose, never repaired.
        case closing
    }

    /// Creates the first terminal of `key` (`create-terminal`, which adds the
    /// first screen and pane). Returns the new surface. Tests replace it.
    var create: @MainActor (WorkspaceKey) async throws -> SurfaceID?
    /// Whether commands can run now. Tests replace it.
    var canCreate: @MainActor () -> Bool
    private(set) var states: [WorkspaceKey: FirstTerminal] = [:]
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
    }

    /// Checks `workspace` after a store change. When it has no pane and no
    /// path owns its first terminal, sends one create-terminal and calls
    /// `created` with the new surface.
    func check(_ workspace: WorkspaceModel, created: @escaping @MainActor (SurfaceID) -> Void) {
        guard let key = workspace.key else { return }
        guard workspace.screens.allSatisfy(\.panes.isEmpty) else {
            // Populated: whoever created the terminal is done, unless this
            // app is still inside its own populate call or closing it.
            if states[key] == .awaitingPane { states[key] = nil }
            return
        }
        guard states[key] == nil, canCreate() else { return }
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
