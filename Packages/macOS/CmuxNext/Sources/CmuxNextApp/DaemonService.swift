import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Observation
import os

/// Process-wide connection to the cmux-tui daemon: launches or finds the
/// owner, keeps the mirror (`store`) current once per frame, and runs
/// commands off the main actor with logging.
@Observable
final class DaemonService {
    let store = DaemonStore()
    private(set) var connection: DaemonConnection?
    private(set) var windowState: WindowStateStore?
    private(set) var identity: DaemonIdentity?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let scheduler = DisplayLinkFrameScheduler()
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")

    func start(launch: LaunchIdentity) {
        guard runTask == nil else { return }
        let store = store
        runTask = Task { [weak self, scheduler, logger] in
            do {
                let launcher = try DaemonLauncher.forApp(tag: launch.tag, terminalEnvironment: launch.terminalEnvironment)
                let connection = DaemonConnection(endpointProvider: launcher.endpointProvider)
                let identity = try await connection.start()
                self?.connection = connection
                self?.identity = identity
                self?.windowState = WindowStateStore(connection: connection)
                logger.info("cmux-tui \(identity.version, privacy: .public) session \(identity.session, privacy: .public)")
                await store.run(connection: connection, scheduler: scheduler)
            } catch {
                logger.error("cmux-tui daemon unavailable: \(String(describing: error), privacy: .public)")
                store.markFailed(String(describing: error))
            }
        }
    }

    func supports(_ capability: String) -> Bool {
        identity?.supports(capability) ?? false
    }

    /// The socket for dedicated terminal attachments (re-read on reconnect).
    func endpoint() async throws -> DaemonEndpoint {
        guard let connection, let endpoint = await connection.endpoint else { throw DaemonError.notConnected }
        return endpoint
    }

    /// Runs a command and logs a failure. Returns false when it threw.
    @discardableResult
    func run(_ label: String, _ body: @Sendable (DaemonConnection) async throws -> Void) async -> Bool {
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            return false
        }
        do {
            try await body(connection)
            return true
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Fire-and-forget variant for UI handlers.
    func send(_ label: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        Task { await run(label, body) }
    }

    /// Runs an intent with an optimistic store patch settled by the daemon's
    /// transaction echo (or reverted on failure).
    func perform(_ label: String, patch: OptimisticPatch, expectEcho: Bool = false,
                 _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) async -> Bool {
        guard let connection else { return false }
        do {
            try await store.perform(patch, expectEcho: expectEcho) { transaction in
                try await body(connection, transaction)
            }
            return true
        } catch {
            logger.error("\(label, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Asks for a fresh snapshot (after commands whose effect has no delta).
    func refresh() {
        guard let connection else { return }
        let store = store
        Task {
            if let (tree, _) = try? await connection.snapshot() { store.apply(snapshot: tree) }
        }
    }

    func shutdownConnection() {
        runTask?.cancel()
        if let connection { Task { await connection.close() } }
    }
}
