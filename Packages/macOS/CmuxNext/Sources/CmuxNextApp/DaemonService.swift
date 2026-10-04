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
    /// Set while an administrator turned this machine's feature off: no endpoint, no re-attach.
    let policyBlock = PolicyBlock()
    private(set) var connection: DaemonConnection?
    private(set) var windowState: WindowStateStore?
    /// The current (or last) daemon's identity. The store owns it and
    /// replaces it on every handshake, so capabilities follow a daemon that
    /// restarted or was handed off to a newer build after the first connect.
    var identity: DaemonIdentity? { store.identity }
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The running relaunch of kept tabs (`relaunchKeptLayoutIfNeeded`).
    @ObservationIgnored var keptLayoutRelaunch: Task<Void, Never>?
    @ObservationIgnored private let scheduler = FrameBatcher(owner: "DaemonStore.drain")
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")
    /// The window records of the daemon's launch snapshot, drawn before the
    /// first connection (`LaunchSnapshotWindow`); nil without one.
    @ObservationIgnored var launchSnapshotWindows: WindowStateDocument?
    /// The local session whose launch snapshot path each handshake records.
    @ObservationIgnored var launchSnapshotSession: String?
    @ObservationIgnored var launchSnapshotLocation = LaunchSnapshotLocation()
    /// Callers of `endpoint()` waiting for the first connection (terminals
    /// drawn from the launch snapshot attach as soon as it exists).
    @ObservationIgnored var connectionWaiters: [CheckedContinuation<Void, Never>] = []

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
    @ObservationIgnored var startupDeadline: Duration = DaemonStartup.shared.defaultDeadline
    @ObservationIgnored var startupClock: any Clock<Duration> = ContinuousClock()
    @ObservationIgnored private var startupDeadlineTimer: DemandTimer?
    @ObservationIgnored private var lastStartupError: DaemonError?
    /// Events that may let a failed connect succeed: the daemon socket
    /// changing (watched by the connection), the app becoming active, and
    /// for a Cloud machine a network path change. Retries past their timed
    /// budget wait only for these (no polling).
    @ObservationIgnored private(set) var retryWake: RetryWake
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    /// `terminalEnvironment` (`AppEnvironment.terminalEnvironment`) goes to
    /// the daemon process and to every terminal it creates for this app.
    /// `prestart` is the first connect attempt `main` began
    /// (`DaemonService.prestart`); without one the first attempt starts here.
    func start(launch: LaunchIdentity, terminalEnvironment: [String: String],
               terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String],
               prestart: DaemonPrestart? = nil) {
        guard runTask == nil else { return }
        let launcher: DaemonLauncher
        if let prestart {
            launcher = prestart.launcher
            retryWake = prestart.wake
        } else {
            do {
                launcher = try DaemonLauncher.forApp(tag: launch.tag, terminalEnvironment: terminalEnvironment)
            } catch {
                noteStartupFailure((error as? DaemonError) ?? .launchFailed(String(describing: error)))
                return
            }
        }
        if let session = try? DaemonLauncher.sessionName(tag: launch.tag) {
            launchSnapshotSession = session
            showLaunchSnapshot(session: session)
        }
        let configuration = DaemonConnection.Configuration(
            retryWake: retryWake,
            terminalEnvironment: terminalEnvironmentProvider,
            sessionEvents: true)
        var first: (@Sendable () async -> DaemonPrestart.Outcome)?
        if let prestart {
            // Cancelling the startup (shutdown) cancels the attempt too.
            first = { @Sendable in
                await withTaskCancellationHandler { await prestart.outcome() } onCancel: { prestart.cancel() }
            }
        }
        // After an update the daemon may still be the previous build's: hand
        // it off to the bundled build; terminals survive (their hosts are
        // adopted by the new daemon) and the connection reconnects by itself.
        let logger = logger
        let afterConnect: @Sendable (DaemonConnection, DaemonIdentity) async -> Void = { connection, identity in
            let decision = await launcher.handOffIfStale(identity: identity, using: connection)
            if case .restart(let running, let bundled) = decision {
                DebugTimings.markLaunch("daemon_version_handoff")
                logger.info("daemon handoff \(running, privacy: .public) -> \(bundled, privacy: .public)")
            }
        }
        start(first: first, afterConnect: afterConnect) {
            DaemonConnection(configuration: configuration, endpointProvider: launcher.endpointProvider)
        }
    }


    /// Connects with `makeConnection`, retrying the first connect until it
    /// succeeds (`DaemonStartup`), then mirrors the connection into `store`.
    /// The connection reconnects by itself afterwards.
    func start(first: (@Sendable () async -> DaemonPrestart.Outcome)? = nil,
               afterConnect: (@Sendable (DaemonConnection, DaemonIdentity) async -> Void)? = nil,
               makeConnection: @escaping @Sendable () -> DaemonConnection) {
        guard runTask == nil else { return }
        let store = store
        armStartupDeadline()
        observeRetryEvents()
        let wake = retryWake
        runTask = Task { [weak self, scheduler, logger] in
            let clock = self?.startupClock ?? ContinuousClock()
            weak let weakSelf = self
            let connected = await DaemonStartup.shared.connect(wake: wake, clock: clock, first: first,
                                                               makeConnection: makeConnection) { error in
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
            // task-owner: one hop to read the endpoint; the store run below owns the connection
            Task { await self.rememberSocket(identity, connection: connection) }
            if let afterConnect {
                // task-owner: one version check per first connect; its request carries the control deadline
                Task { await afterConnect(connection, identity) }
            }
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
    /// An incompatible daemon (`compatibility` says so) is retried only on
    /// such an event: the machine's daemon can be updated in place behind
    /// the same link, and the next event then connects to the new build.
    func start(remote endpoint: @escaping @Sendable () async throws -> String) {
        guard runTask == nil, !policyBlock.isBlocked else { return }
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
                let connected = await DaemonStartup.shared.connect(wake: wake, clock: clock) {
                    DaemonConnection(configuration: DaemonConnection.Configuration(retryWake: wake, terminalEnvironment: nil,
                                                                                    sessionEvents: true)) {
                        DaemonEndpoint(socketPath: try await endpoint())
                    }
                } onFailure: { error in
                    logger.error("\(machineID, privacy: .public): daemon unavailable: \(error.description, privacy: .public)")
                    // Before the failure is published: an event from then on
                    // (the machine updated, app activation) wakes the wait below.
                    if DaemonStartup.shared.isPermanent(error) { wake.rebaseline() }
                    await weakSelf?.noteStartupFailure(error)
                }
                if Task.isCancelled { return }
                guard let (connection, identity) = connected else {
                    // Incompatible daemon: wait for an event only, then try again.
                    guard await wake.awaitWake(delay: nil, clock: clock) != .cancelled else { return }
                    continue
                }
                guard let self, !Task.isCancelled else { return }
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
        DebugTimings.markLaunch("daemon_connected")
        self.connection = connection
        rememberLaunchSnapshot(identity)
        resumeConnectionWaiters()
        store.noteHandshake(identity)
        startupDeadlineTimer?.cancel()
        startupDeadlineTimer = nil
        lastStartupError = nil
        startup = .connected
        relaunchKeptLayoutIfNeeded(connection)
    }

    /// Records a failed first-connect attempt. Shows as unavailable once the
    /// deadline has passed, or at once when retrying cannot help.
    func noteStartupFailure(_ error: DaemonError) {
        logger.error("cmux-tui daemon unavailable: \(error.description, privacy: .public)")
        lastStartupError = error
        store.markFailed(error.description)
        if startup.isUnavailable || DaemonStartup.shared.isPermanent(error) {
            startup = .unavailable(error)
            resumeConnectionWaiters()
        }
    }

    private func armStartupDeadline() {
        startupDeadlineTimer?.cancel()
        let timer = DemandTimer(owner: "DaemonService.startupDeadline", clock: startupClock)
        startupDeadlineTimer = timer
        timer.schedule(after: startupDeadline) { @MainActor [weak self] in
            guard let self, self.startup == .connecting else { return }
            self.startup = .unavailable(self.lastStartupError ?? .timedOut("first connection to cmux-tui"))
            self.resumeConnectionWaiters()
        }
    }

    func supports(_ capability: String) -> Bool {
        store.supports(capability)
    }

    /// The socket for dedicated terminal attachments (re-read on reconnect).
    func endpoint() async throws -> DaemonEndpoint {
        if policyBlock.isBlocked { throw DaemonError.endpointBlocked("turned off by your organization") }
        if connection == nil, startup == .connecting, isStarting { await firstConnection() }
        guard let connection, let endpoint = await connection.endpoint else { throw DaemonError.notConnected }
        return endpoint
    }

    /// True once `start` began connecting.
    var isStarting: Bool { runTask != nil }

    /// Runs a command and logs a failure. Returns false when it threw.
    @discardableResult
    func run(_ label: String, _ body: @Sendable (DaemonConnection) async throws -> Void) async -> Bool {
        await failure(label, ticket: openTicket(), body) == nil
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
        let ticket = openTicket()
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            await closeTicket(ticket, label: label, error: DaemonError.notConnected)
            return .failed
        }
        do {
            try await body(connection)
            await closeTicket(ticket, label: label, error: nil, replying: connection)
            return .succeeded
        } catch DaemonError.timedOut(let what) {
            logger.info("\(label, privacy: .public) outcome unknown: \(what, privacy: .public)")
            await closeTicket(ticket, label: label, error: DaemonError.timedOut(what))
            return .unknown
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return .failed
        }
    }

    /// Fire-and-forget variant for UI handlers.
    func send(_ label: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        // Always start the task; `workTracker?(Task {...})` would skip
        // creating it (and drop the command) when no tracker is set.
        // The ticket opens now, so an action that awaits its scope waits
        // for this command even before the task starts.
        let ticket = openTicket()
        let task = Task { await failure(label, ticket: ticket, body) }
        workTracker?(task)
    }

    /// Runs a command; returns nil on success, else the failure (logged).
    func failure(_ label: String, _ body: @Sendable (DaemonConnection) async throws -> Void) async -> ActionWorkFailure? {
        await failure(label, ticket: openTicket(), body)
    }

    private func failure(_ label: String, ticket: CommandTicket?,
                         _ body: @Sendable (DaemonConnection) async throws -> Void) async -> ActionWorkFailure? {
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            await closeTicket(ticket, label: label, error: DaemonError.notConnected)
            return "\(label): not connected to cmux-tui"
        }
        do {
            try await body(connection)
            await closeTicket(ticket, label: label, error: nil, replying: connection)
            return nil
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return ActionWorkFailure(label, error)
        }
    }

    /// Receives every command task `send` starts, so an action run from the
    /// control socket can await it (`ActionRegistry.track`).
    @ObservationIgnored var workTracker: ((ActionWork) -> Void)?

    func shutdownConnection() {
        startupDeadlineTimer?.cancel()
        startupDeadlineTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        runTask?.cancel()
        runTask = nil
        keptLayoutRelaunch?.cancel()
        keptLayoutRelaunch = nil
        // task-owner: teardown hop; close() is idempotent and finishes the store pump
        if let connection { Task { await connection.close() } }
        connection = nil
    }
}
