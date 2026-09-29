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
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    @ObservationIgnored private var queuedReconcile: Task<Void, Never>?
    @ObservationIgnored private let scheduler = DisplayLinkFrameScheduler()
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")

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

    /// Outcome of a command whose reply may miss its deadline.
    enum CommandOutcome {
        case succeeded
        case failed
        /// The deadline passed: the daemon may still apply the command.
        case unknown
    }

    /// Like ``run(_:_:)``, but tells a deadline miss (outcome unknown) apart
    /// from a failure, so callers can reconcile instead of reverting.
    func runReportingTimeout(_ label: String, _ body: @Sendable (DaemonConnection) async throws -> Void) async -> CommandOutcome {
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            return .failed
        }
        do {
            try await body(connection)
            return .succeeded
        } catch DaemonError.timedOut(let what) {
            logger.info("\(label, privacy: .public) outcome unknown: \(what, privacy: .public)")
            return .unknown
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// Fetches and applies a snapshot. Requests on the control connection
    /// are answered in order, so the snapshot reflects every command sent
    /// before it, including ones whose replies missed their deadline.
    /// Concurrent callers share snapshots: a caller joins the snapshot
    /// queued behind the one in flight (so it is ordered after the caller's
    /// commands), and at most one is queued.
    func reconcile() async {
        if let queuedReconcile {
            await queuedReconcile.value
            return
        }
        let previous = reconciling
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.queuedReconcile = nil
            if let connection = self.connection, let (tree, _) = try? await connection.snapshot() {
                self.store.apply(snapshot: tree)
            }
        }
        if previous != nil { queuedReconcile = task }
        reconciling = task
        await task.value
        if reconciling == task { reconciling = nil }
    }

    /// Fire-and-forget variant for UI handlers.
    func send(_ label: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        workTracker?(Task { await failure(label, body) })
    }

    /// Runs a command; returns nil on success, else the failure (logged).
    func failure(_ label: String, _ body: @Sendable (DaemonConnection) async throws -> Void) async -> String? {
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            return "\(label): not connected to cmux-tui"
        }
        do {
            try await body(connection)
            return nil
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return "\(label): \(error)"
        }
    }

    /// Receives every command task `send` starts, so an action run from the
    /// control socket can await it (`ActionRegistry.track`).
    @ObservationIgnored var workTracker: ((Task<String?, Never>) -> Void)?

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
        if let connection { Task { await connection.close() } }
    }
}
