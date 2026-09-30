import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Network
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
    /// The current (or last) daemon's identity. The store owns it and
    /// replaces it on every handshake, so capabilities follow a daemon that
    /// restarted or was handed off to a newer build after the first connect.
    var identity: DaemonIdentity? { store.identity }
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    @ObservationIgnored private var queuedReconcile: Task<Void, Never>?
    @ObservationIgnored private let scheduler = FrameBatcher(owner: "DaemonStore.drain")
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")

    init(machineID: String = "local") {
        self.machineID = machineID
        retryWake = RetryWake(owner: "DaemonService.retry \(machineID)")
    }

    /// Fires `retryWake` when the app becomes active.
    private func observeRetryEvents() {
        guard activationObserver == nil else { return }
        let wake = retryWake
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in wake.fire() }
    }

    var isLocal: Bool { machineID == "local" }

    /// Directory new terminals start in: the Mac's home for the local
    /// daemon; nil (the machine's own default) on a Cloud machine, where a
    /// Mac path does not exist.
    var defaultCwd: String? { isLocal ? NSHomeDirectory() : nil }

    /// How the first connection is going (window connecting state, control
    /// errors). Becomes `.unavailable` after `startupDeadline` or on an
    /// incompatible daemon; retrying continues in the background.
    private(set) var startup: DaemonStartupState = .connecting
    @ObservationIgnored var startupDeadline: Duration = DaemonStartup.defaultDeadline
    @ObservationIgnored var startupClock: any Clock<Duration> = ContinuousClock()
    @ObservationIgnored private var startupDeadlineTimer: DemandTimer?
    @ObservationIgnored private var lastStartupError: DaemonError?
    /// Events that may let a failed connect succeed: the daemon socket
    /// changing (watched by the connection), the app becoming active, and
    /// for a Cloud machine a network path change. Retries past their timed
    /// budget wait only for these (no polling).
    @ObservationIgnored let retryWake: RetryWake
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    /// `terminalEnvironment` (`AppEnvironment.terminalEnvironment`) goes to
    /// the daemon process and to every terminal it creates for this app.
    func start(launch: LaunchIdentity, terminalEnvironment: [String: String]) {
        guard runTask == nil else { return }
        let launcher: DaemonLauncher
        do {
            launcher = try DaemonLauncher.forApp(tag: launch.tag, terminalEnvironment: terminalEnvironment)
        } catch {
            noteStartupFailure((error as? DaemonError) ?? .launchFailed(String(describing: error)))
            return
        }
        let configuration = DaemonConnection.Configuration(
            retryWake: retryWake,
            terminalEnvironment: TerminalEnvironment.shared(overrides: terminalEnvironment))
        start { DaemonConnection(configuration: configuration, endpointProvider: launcher.endpointProvider) }
    }

    /// Connects with `makeConnection`, retrying the first connect until it
    /// succeeds (`DaemonStartup`), then mirrors the connection into `store`.
    /// The connection reconnects by itself afterwards.
    func start(makeConnection: @escaping @Sendable () -> DaemonConnection) {
        guard runTask == nil else { return }
        let store = store
        armStartupDeadline()
        observeRetryEvents()
        let wake = retryWake
        runTask = Task { [weak self, scheduler, logger] in
            let clock = self?.startupClock ?? ContinuousClock()
            weak let weakSelf = self
            let connected = await DaemonStartup.connect(wake: wake, clock: clock, makeConnection: makeConnection) { error in
                await weakSelf?.noteStartupFailure(error)
            }
            guard let (connection, identity) = connected else { return }
            guard let self, !Task.isCancelled else {
                await connection.close()
                return
            }
            self.didConnect(connection, identity: identity)
            self.windowState = WindowStateStore(connection: connection)
            logger.info("cmux-tui \(identity.version, privacy: .public) session \(identity.session, privacy: .public)")
            await store.run(connection: connection, scheduler: scheduler)
        }
    }

    /// Connects to a remote daemon through `endpoint` (a Cloud machine's link
    /// socket). The first connect is retried with capped backoff
    /// (`DaemonStartup`); afterwards the connection reconnects by itself,
    /// re-asking `endpoint` (which restarts a dead link). A connection that
    /// ends for good is replaced the same way, spaced by one backoff across
    /// such ends. Retries past their budget wait for a network path change,
    /// app activation or the link socket changing, never a fixed period.
    func start(remote endpoint: @escaping @Sendable () async throws -> String) {
        guard runTask == nil else { return }
        let store = store
        let machineID = machineID
        armStartupDeadline()
        observeRetryEvents()
        let wake = retryWake
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied { wake.fire() }
        }
        monitor.start(queue: DispatchQueue(label: "com.cmuxterm.next.daemon.path.\(machineID)"))
        pathMonitor = monitor
        let clock = startupClock
        runTask = Task { [weak self, scheduler, logger] in
            weak let weakSelf = self
            var ends = RetryPacer(.firstConnect)
            // wakeup-allow: each iteration runs a connection to its end, then waits in RetryPacer
            while !Task.isCancelled {
                let connected = await DaemonStartup.connect(wake: wake, clock: clock) {
                    DaemonConnection(configuration: DaemonConnection.Configuration(retryWake: wake, terminalEnvironment: nil)) {
                        DaemonEndpoint(socketPath: try await endpoint())
                    }
                } onFailure: { error in
                    logger.error("\(machineID, privacy: .public): daemon unavailable: \(error.description, privacy: .public)")
                    await weakSelf?.noteStartupFailure(error)
                }
                guard let (connection, identity) = connected, let self, !Task.isCancelled else { return }
                self.didConnect(connection, identity: identity)
                logger.info("\(machineID, privacy: .public): cmux-tui \(identity.version, privacy: .public) session \(identity.session, privacy: .public)")
                await store.run(connection: connection, scheduler: scheduler)
                await connection.close()
                if Task.isCancelled { return }
                guard await ends.waitAfterFailure(wake: wake, clock: clock) else { return }
            }
        }
    }

    private func didConnect(_ connection: DaemonConnection, identity: DaemonIdentity) {
        self.connection = connection
        store.noteHandshake(identity)
        startupDeadlineTimer?.cancel()
        startupDeadlineTimer = nil
        lastStartupError = nil
        startup = .connected
    }

    /// Records a failed first-connect attempt. Shows as unavailable once the
    /// deadline has passed, or at once when retrying cannot help.
    func noteStartupFailure(_ error: DaemonError) {
        logger.error("cmux-tui daemon unavailable: \(error.description, privacy: .public)")
        lastStartupError = error
        store.markFailed(error.description)
        if startup.isUnavailable || DaemonStartup.isPermanent(error) { startup = .unavailable(error) }
    }

    private func armStartupDeadline() {
        startupDeadlineTimer?.cancel()
        let timer = DemandTimer(owner: "DaemonService.startupDeadline", clock: startupClock)
        startupDeadlineTimer = timer
        timer.schedule(after: startupDeadline) { @MainActor [weak self] in
            guard let self, self.startup == .connecting else { return }
            self.startup = .unavailable(self.lastStartupError ?? .timedOut("first connection to cmux-tui"))
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
        // Always start the task; `workTracker?(Task {...})` would skip
        // creating it (and drop the command) when no tracker is set.
        let task = Task { await failure(label, body) }
        workTracker?(task)
    }

    /// Runs a command; returns nil on success, else the failure (logged).
    func failure(_ label: String, _ body: @Sendable (DaemonConnection) async throws -> Void) async -> ActionWorkFailure? {
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            return "\(label): not connected to cmux-tui"
        }
        do {
            try await body(connection)
            return nil
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return ActionWorkFailure(label, error)
        }
    }

    /// Receives every command task `send` starts, so an action run from the
    /// control socket can await it (`ActionRegistry.track`).
    @ObservationIgnored var workTracker: ((ActionWork) -> Void)?

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

    func shutdownConnection() {
        startupDeadlineTimer?.cancel()
        startupDeadlineTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        runTask?.cancel()
        runTask = nil
        // task-owner: teardown hop; close() is idempotent and finishes the store pump
        if let connection { Task { await connection.close() } }
        connection = nil
    }
}
