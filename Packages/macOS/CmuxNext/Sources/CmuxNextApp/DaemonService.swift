import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Observation
import os

/// One machine's cmux-tui daemon connection: the local daemon (launched or
/// found by `start(launch:)`) or a Cloud machine reached through its link
/// socket (`start(remote:)`). Keeps the mirror (`store`) current once per
/// frame and runs commands off the main actor with logging.
@Observable
final class DaemonService {
    /// `local`, or the Cloud machine id (`vm-…`).
    let machineID: String
    let store = DaemonStore()
    private(set) var connection: DaemonConnection?
    private(set) var windowState: WindowStateStore?
    private(set) var identity: DaemonIdentity?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let scheduler = DisplayLinkFrameScheduler()
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")

    init(machineID: String = "local") {
        self.machineID = machineID
    }

    var isLocal: Bool { machineID == "local" }

    /// Directory new terminals start in: the Mac's home for the local
    /// daemon; nil (the machine's own default) on a Cloud machine, where a
    /// Mac path does not exist.
    var defaultCwd: String? { isLocal ? NSHomeDirectory() : nil }

    func start(launch: LaunchIdentity) {
        guard runTask == nil else { return }
        let store = store
        runTask = Task { [weak self, scheduler, logger] in
            do {
                let launcher = try DaemonLauncher.forApp(tag: launch.tag, terminalEnvironment: launch.terminalEnvironment)
                let configuration = DaemonConnection.Configuration(
                    terminalEnvironment: TerminalEnvironment.shared(overrides: launch.terminalEnvironment))
                let connection = DaemonConnection(configuration: configuration, endpointProvider: launcher.endpointProvider)
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

    /// Connects to a remote daemon through `endpoint` (a Cloud machine's link
    /// socket). The first connect is retried with capped backoff until it
    /// succeeds or `shutdownConnection()` runs; afterwards the connection
    /// reconnects by itself, re-asking `endpoint` (which restarts a dead
    /// link). A connection that ends for good is replaced the same way.
    func start(remote endpoint: @escaping @Sendable () async throws -> String) {
        guard runTask == nil else { return }
        let store = store
        let machineID = machineID
        runTask = Task { [weak self, scheduler, logger] in
            let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]
            var attempt = 0
            while !Task.isCancelled {
                let configuration = DaemonConnection.Configuration(terminalEnvironment: nil)
                let connection = DaemonConnection(configuration: configuration) { DaemonEndpoint(socketPath: try await endpoint()) }
                do {
                    let identity = try await connection.start()
                    attempt = 0
                    self?.connection = connection
                    self?.identity = identity
                    logger.info("\(machineID, privacy: .public): cmux-tui \(identity.version, privacy: .public) session \(identity.session, privacy: .public)")
                    await store.run(connection: connection, scheduler: scheduler)
                } catch {
                    await connection.close()
                    if Task.isCancelled { return }
                    logger.error("\(machineID, privacy: .public): daemon unavailable: \(String(describing: error), privacy: .public)")
                    store.markFailed(String(describing: error))
                }
                if Task.isCancelled { return }
                let delay = delays[min(attempt, delays.count - 1)]
                attempt += 1
                do { try await ContinuousClock().sleep(for: delay) } catch { return }
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

    /// Like `perform`, with a caller-chosen transaction (a drag commit keeps
    /// one id from drop to settle). Returns the body's value, or nil when the
    /// command threw (the patch is then reverted).
    func commit<T: Sendable>(_ label: String, patch: OptimisticPatch, transaction: ClientTransactionID, expectEcho: Bool,
                             _ body: @Sendable (DaemonConnection) async throws -> T) async -> T? {
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            return nil
        }
        store.applyOptimistic(patch, transaction: transaction)
        do {
            let value = try await body(connection)
            if !expectEcho { store.settleOptimistic(transaction) }
            return value
        } catch {
            store.rejectOptimistic(transaction)
            logger.error("\(label, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            return nil
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
        runTask = nil
        if let connection { Task { await connection.close() } }
        connection = nil
    }
}
