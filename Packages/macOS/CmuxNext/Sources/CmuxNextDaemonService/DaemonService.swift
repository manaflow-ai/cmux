import AppKit
public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextControl
public import CmuxNextDaemon
public import CmuxNextWakeups
public import Foundation
import Network
public import Observation
public import os

/// A command body run against a daemon connection. It runs isolated to the
/// connection actor, off the caller's actor: under
/// NonisolatedNonsendingByDefault a plain async closure type would run its
/// synchronous parts (JSON encode/decode, string work) on the main actor of
/// every `send`/`run` caller. The connection actor (not `@concurrent`, which
/// hops to the global pool) keeps fire-and-forget commands in the order the
/// main actor started them.
public typealias DaemonCommandBody = @Sendable (isolated DaemonConnection) async throws -> Void

/// One machine's cmux-tui daemon connection: the local daemon (launched or
/// found by `start(launch:)`) or a Cloud machine reached through its link
/// socket (`start(remote:)`). Keeps the mirror (`store`) current once per
/// frame and runs commands off the main actor with logging.
@Observable
public final class DaemonService {
    /// `local`, or the Cloud machine id (`vm-…`).
    public let machineID: String
    /// Its connections echo `placement-shift-v1` (this build orders sidebar rows from the
    /// sidebar document; ``DaemonConnectionConfiguration/echoesPlacementShift``).
    let echoesPlacementShift: Bool
    public let store = DaemonStore()
    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.creation.hold` / `debug.creation.release`: this daemon's creations whose reply a test holds.
    public let creationHold = DebugCreationHold()
    #endif
    /// Set while an administrator turned this machine's feature off: no endpoint, no re-attach.
    public let policyBlock = PolicyBlock()
    /// The last ordered send to each terminal surface (``sendInOrder(_:to:_:)``): the next one waits for it.
    @ObservationIgnored var orderedSends: [SurfaceID: (serial: UInt64, work: ActionWork)] = [:]
    @ObservationIgnored var orderedSendSerial: UInt64 = 0
    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.close.hold` / `debug.close.release`: this daemon's close warning reads that a test holds.
    public let closeReadHold = DebugCloseReadHold()
    #endif
    /// Retry Now and Restart cmux-tui while the local daemon cannot be reached (cx-jniyz.1).
    public let recovery = DaemonRecovery()
    public private(set) var connection: DaemonConnection?
    public private(set) var windowState: WindowStateStore?
    /// The colors this app paints the daemon's terminals with, sent at every
    /// connect and on every change so the daemon answers OSC 10/11/12 queries
    /// with them (DaemonService+TerminalColors). Nil until the app knows them.
    public var terminalDefaultColors: TerminalDefaultColors? {
        didSet { if terminalDefaultColors != oldValue { pushTerminalDefaultColors() } }
    }
    /// The running push of `terminalDefaultColors`, and whether a newer value waits for it.
    @ObservationIgnored var terminalColorsPush: Task<Void, Never>?
    @ObservationIgnored var terminalColorsPending = false
    /// The current (or last) daemon's identity. The store owns it and
    /// replaces it on every handshake, so capabilities follow a daemon that
    /// restarted or was handed off to a newer build after the first connect.
    public var identity: DaemonIdentity? { store.identity }
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The running relaunch of kept tabs (`relaunchKeptLayoutIfNeeded`).
    @ObservationIgnored var keptLayoutRelaunch: Task<Void, Never>?
    /// Parked tabs whose `restart-tab` is in flight (`wakeParkedTabs`).
    @ObservationIgnored var wakingParkedTabs: Set<SurfaceID> = []
    /// Which kept tabs this launch restarts (`restartsKeptTab`), observed by the tab cells.
    public internal(set) var keptTabRestarts: KeptTabRestarts = .none
    /// The connection Quit's end choice runs on, kept after
    /// `shutdownConnection` so Retry ends the same daemon (`endSessionsAndStop`).
    @ObservationIgnored var endingConnection: DaemonConnection?
    /// The daemon's event batches, on the frame class (every frame, whole, unbudgeted): a batch holds
    /// the echoes of the person's own actions, and most of them have no intent (close other tabs, close
    /// a workspace, duplicate, move to a new window, reopen), so the echo is the first time the change
    /// shows. Under a budgeted class it waited while a key was pending or other visible work spent the
    /// frame, and the backlog grew without bound under steady churn (review 2 of pl-main-bc).
    @ObservationIgnored let drainScheduler: FrameBatcher
    @ObservationIgnored public let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")
    /// The window records of the daemon's launch snapshot, drawn before the
    /// first connection (`LaunchSnapshotWindow`); nil without one.
    @ObservationIgnored public var launchSnapshotWindows: WindowStateDocument?
    /// The sidebar document the launch snapshot saved (`LaunchSnapshot.sidebarDoc`), shown before the handshake.
    @ObservationIgnored public var launchSnapshotSidebarDoc: Data?
    /// The local session whose launch snapshot path each handshake records.
    @ObservationIgnored var launchSnapshotSession: String?
    @ObservationIgnored var launchSnapshotLocation = LaunchSnapshotLocation()
    /// Callers of `endpoint()` waiting for the first connection (terminals
    /// drawn from the launch snapshot attach as soon as it exists).
    @ObservationIgnored var connectionWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - machineID: `local`, or the remote machine's id.
    ///   - echoesPlacementShift: The App passes `SidebarMirror.isLinked`; tests leave it off.
    ///   - mainWork: The app's main-thread scheduler (``MainWorkScheduler``), built at its composition
    ///     root and passed by init; a remote machine's service gets the same one (one main thread, one
    ///     budget). The service keeps only the batcher it builds on it (a test passes one it ticks by hand).
    public init(machineID: String = "local", echoesPlacementShift: Bool = false, mainWork: MainWorkScheduler) {
        self.machineID = machineID
        self.echoesPlacementShift = echoesPlacementShift
        drainScheduler = FrameBatcher(owner: "DaemonStore.drain", scheduler: mainWork.frames)
        retryWake = RetryWake(owner: "DaemonService.retry \(machineID)")
        // The local daemon's kept tabs restart at its first connect (`relaunchKeptLayoutIfNeeded`).
        keptTabRestarts = isLocal ? .expected : .none
    }

    /// Records a launch milestone (`daemon_connected`, `launch_snapshot_applied`,
    /// `daemon_version_handoff`) for every service. The App sets it to its launch
    /// timing log (`DebugTimings.markLaunch`) before the first service starts.
    public nonisolated static var launchMark: @Sendable (String) -> Void {
        get { launchMarkSink.withLock { $0 } }
        set { launchMarkSink.withLock { $0 = newValue } }
    }
    /// The local connection's daemon-request probe (``newRequestLatency()``), set by `start(launch:…)`;
    /// `debug.daemon_requests` reads it off the main actor.
    nonisolated let requestLatency = RequestLatencySlot()
    private nonisolated static let launchMarkSink = Mutex<@Sendable (String) -> Void>({ _ in })

    /// Fires `retryWake` when the app becomes active.
    private func observeRetryEvents() {
        guard activationObserver == nil else { return }
        let wake = retryWake
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in wake.fire() }
    }

    /// How the first connection is going (window connecting state, control
    /// errors). Becomes `.unavailable` after `startupDeadline` or on an
    /// incompatible daemon; retrying continues in the background.
    public private(set) var startup: DaemonStartupState = .connecting
    @ObservationIgnored var startupDeadline: Duration = DaemonStartup.shared.defaultDeadline
    @ObservationIgnored var startupClock: any Clock<Duration> = ContinuousClock()
    /// Times the wait for a reopened workspace to reach the mirror
    /// (`DaemonStore.workspace(afterReopen:)`); tests advance it.
    @ObservationIgnored public var reopenClock: any Clock<Duration> = ContinuousClock()
    @ObservationIgnored private var startupDeadlineTimer: DemandTimer?
    /// The last failed connect attempt until a connection succeeds (`notConnectedReason`).
    @ObservationIgnored private(set) var lastStartupError: DaemonError?
    /// Events that may let a failed connect succeed: the daemon socket
    /// changing (watched by the connection), the app becoming active, and
    /// for a Cloud machine a network path change. Retries past their timed
    /// budget wait only for these (no polling).
    @ObservationIgnored public private(set) var retryWake: RetryWake
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    /// Starts a fresh daemon connection attempt. This is deliberately synchronous: callers
    /// stamp their transport attempt and clear its failure before waking the asynchronous loop.
    public func beginAttempt() {
        startup = .connecting
        lastStartupError = nil
        armStartupDeadline()
    }
    /// How the connections reach this app's daemon (the page relay opens its own with it).
    @ObservationIgnored public private(set) var endpointProvider: DaemonConnection.EndpointProvider?
    /// A remote machine's route (`start(remote:)`), for a second connection to its daemon (an
    /// agent chat that runs on that machine); nil for this app's own daemon.
    @ObservationIgnored public private(set) var remoteEndpoint: DaemonConnection.EndpointProvider?
    /// Hands an owner without `ws-listen-v1` off to the bundled build (DaemonService+PageListener).
    @ObservationIgnored var pageListenerHandOff: (@Sendable (DaemonConnection, DaemonIdentity) async -> Bool)?
    /// Hands the local daemon off for a confirmed server-update restart (`restartForUpdate`); nil
    /// for a remote or test service.
    @ObservationIgnored var updateHandOff: (@Sendable (DaemonConnection, DaemonIdentity) async -> Bool)?

    /// `terminalEnvironment` (`AppEnvironment.terminalEnvironment`) goes to
    /// the daemon process and to every terminal it creates for this app.
    /// `prestart` is the first connect attempt `main` began
    /// (`DaemonService.prestart`); without one the first attempt starts here.
    public func start(launch: LaunchIdentity, terminalEnvironment: [String: String],
               terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String],
               resolvesShellIntegration: Bool = false,
               prestart: DaemonPrestart? = nil) {
        guard runTask == nil else { return }
        let launcher: DaemonLauncher
        if let prestart {
            launcher = prestart.launcher
            retryWake = prestart.wake
        } else {
            do {
                launcher = try DaemonLauncher.forApp(build: launch.build,
                                                terminalEnvironment: terminalEnvironment,
                                                daemonEnvironment: Self.firstPartyAppsEnvironment, webSocketPageOrigins: Self.pageOrigins)
            } catch {
                noteStartupFailure((error as? DaemonError) ?? .launchFailed(String(describing: error)), retries: false)
                return
            }
        }
        endpointProvider = launcher.endpointProvider
        recovery.attach(launcher, wake: retryWake)
        // Before the first connection the retry loop has no socket watch of its own (the connection installs one
        // after its first handshake): watch the socket the last launch used and its ready marker, so a daemon
        // that finishes a long restore or handoff wakes a loop past its timed budget (cx-4bd8m).
        if let socket = launcher.configuration.rememberedSocket {
            retryWake.watch(file: socket, companions: [socket + ".websocket.json"])
        }
        pageListenerHandOff = { await launcher.handOffForCapability(DaemonCapability.wsListen.rawValue, identity: $1, using: $0) }
        updateHandOff = { await launcher.handOffForUpdate(identity: $1, using: $0) }
        launchSnapshotSession = launcher.configuration.session
        showLaunchSnapshot(session: launcher.configuration.session, stateDirectory: launcher.configuration.stateDirectory)
        // The prestart's connection records into its probe; later connections record into the same one.
        let latency = prestart.map(\.requestLatency) ?? Self.newRequestLatency()
        requestLatency.set(latency)
        // An owner the handshake refuses (an older protocol, a missing capability) is handed off to
        // the bundled build like one of another build; only a failed handoff shows the refusal.
        let configuration = launcher.handingOffIncompatibleOwners(Self.localConfiguration(
            terminalEnvironment: terminalEnvironmentProvider, resolvesShellIntegration: resolvesShellIntegration,
            installKey: launcher.configuration.installKey, echoesPlacementShift: echoesPlacementShift, retryWake: retryWake,
            requestLatency: latency))
        var first: (@Sendable () async -> DaemonPrestart.Outcome)?
        if let prestart {
            // Cancelling the startup (shutdown) cancels the attempt too.
            first = { @Sendable in
                await withTaskCancellationHandler { await prestart.outcome() } onCancel: { prestart.cancel() }
            }
        }
        // After an update the daemon may still be the previous build's: hand
        // it off to the bundled build before attaching; terminals survive
        // (their hosts are adopted by the new daemon). The bundled build
        // (`--version --json`) is read while the first connect runs, off its path.
        let logger = logger
        // task-owner: one `--version --json` run per start; the handoff check awaits it
        let bundledBuild = prestart?.bundledBuild ?? Task { try? await launcher.bundledBuild() }
        let handOff: @Sendable (DaemonConnection, DaemonIdentity) async -> Bool = { connection, identity in
            let bundled = await bundledBuild.value
            var decision = DaemonService.launchVersionCheck(identity: identity, bundled: bundled)
            if case .restart = decision {
                decision = await launcher.handOffIfStale(identity: identity, using: connection, bundled: bundled)
            }
            guard case .restart(let running, let target) = decision else {
                if case .keep(let reason) = decision, reason != "same build" {
                    logger.notice("daemon \(identity.pid) kept: \(reason, privacy: .public)")
                }
                return false
            }
            DaemonService.launchMark("daemon_version_handoff")
            logger.info("daemon handoff \(running, privacy: .public) -> \(target, privacy: .public)")
            return true
        }
        start(first: first, handOff: handOff) {
            DaemonConnection(configuration: configuration, endpointProvider: launcher.endpointProvider)
        }
    }


    /// Connects with `makeConnection`, retrying the first connect until it
    /// succeeds (`DaemonStartup`), then mirrors the connection into `store`.
    /// The connection reconnects by itself afterwards. `handOff` runs before
    /// the app attaches; true means the daemon is exiting for a version
    /// handoff, so the app connects again and attaches to its successor only.
    public func start(first: (@Sendable () async -> DaemonPrestart.Outcome)? = nil,
               handOff: (@Sendable (DaemonConnection, DaemonIdentity) async -> Bool)? = nil,
               makeConnection: @escaping @Sendable () -> DaemonConnection) {
        guard runTask == nil else { return }
        let store = store
        armStartupDeadline()
        observeRetryEvents()
        let wake = retryWake
        runTask = Task { [weak self, drainScheduler, logger] in
            let clock = self?.startupClock ?? ContinuousClock()
            weak let weakSelf = self
            let onFailure: @Sendable (DaemonError) async -> Void = { error in
                // An incompatible owner is exiting for a handoff to the bundled build: as after a
                // version handoff (below), no failure shows and the deadline covers the successor.
                guard error != .incompatibleOwnerHandedOff else {
                    await weakSelf?.noteIncompatibleOwnerHandoff()
                    return
                }
                await weakSelf?.noteStartupFailure(error)
            }
            // The first connect starts the local daemon too: it keeps trying past its budget (restore fuzz h2).
            var connected = await DaemonStartup.shared.connect(policy: .localFirstConnect, wake: wake, clock: clock, first: first,
                                                               makeConnection: makeConnection, onFailure: onFailure)
            if let (exiting, identity) = connected, let handOff, await handOff(exiting, identity) {
                // The new connection's endpoint waits for the old daemon to
                // exit and starts the bundled build, which adopts the terminals.
                await exiting.closeAndWait()
                // The first connect was in time; the deadline now covers
                // the successor's start.
                self?.armStartupDeadline()
                connected = nil
                if !Task.isCancelled {
                    connected = await DaemonStartup.shared.connect(policy: .localFirstConnect, wake: wake, clock: clock,
                                                                   makeConnection: makeConnection, onFailure: onFailure)
                }
            }
            guard let (connection, identity) = connected else { return }
            guard let self, !Task.isCancelled else {
                await connection.closeAndWait()
                return
            }
            await connection.observePaneNotReady(self.paneNotReadyReporter)
            self.didConnect(connection, identity: identity)
            self.windowState = WindowStateStore(connection: connection)
            logger.info("cmux-tui \(identity.version, privacy: .public) session \(identity.session, privacy: .public)")
            // task-owner: one hop to read the endpoint; the store run below owns the connection
            Task { await self.rememberSocket(identity, connection: connection) }
            await store.run(connection: connection, scheduler: drainScheduler)
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
    /// `admit` checks each handshake's identity before use; when it throws,
    /// the connection closes, the service stops and the store shows why.
    /// `bridge`: each connection runs this child instead of connecting to the
    /// socket (``DaemonEndpoint/bridge``). `onEnd` runs on each drop (EOF, heartbeat).
    public func start(remote endpoint: @escaping @Sendable () async throws -> String, bridge: DaemonBridge? = nil,
               admit: (@MainActor (DaemonIdentity) throws -> Void)? = nil, onEnd: (@MainActor () -> Void)? = nil) {
        guard runTask == nil, !policyBlock.isBlocked else { return }
        remoteEndpoint = { DaemonEndpoint(socketPath: try await endpoint()) }
        let store = store
        if let onEnd { store.onDisconnected = onEnd }
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
        var configuration = DaemonConnection.Configuration(retryWake: wake, terminalEnvironment: nil, sessionEvents: true)
        configuration.echoesPlacementShift = echoesPlacementShift
        runTask = Task { [weak self, drainScheduler, logger, configuration] in
            weak let weakSelf = self
            var ends = RetryPacer(.firstConnect)
            // wakeup-allow: each iteration runs a connection to its end, then waits in RetryPacer
            while !Task.isCancelled {
                let connected = await DaemonStartup.shared.connect(wake: wake, clock: clock) {
                    DaemonConnection(configuration: configuration) {
                        DaemonEndpoint(socketPath: try await endpoint(), bridge: bridge)
                    }
                } onFailure: { error in
                    logger.error("\(machineID, privacy: .public): daemon unavailable: \(error.description, privacy: .public)")
                    // Before the failure is published: an event from then on
                    // (the machine updated, app activation) wakes the wait below.
                    if DaemonStartup.shared.isPermanent(error) { wake.rebaseline() }
                    await weakSelf?.noteStartupFailure(error)
                }
                if Task.isCancelled {
                    await connected?.0.closeAndWait()
                    return
                }
                guard let (connection, identity) = connected else {
                    // Incompatible daemon: wait for an event only, then try again.
                    guard await wake.awaitWake(delay: nil, clock: clock) != .cancelled else { return }
                    continue
                }
                guard let self, !Task.isCancelled else {
                    await connection.closeAndWait()
                    return
                }
                do {
                    try admit?(identity)
                } catch {
                    logger.error("\(machineID, privacy: .public): refused the daemon after the handshake: \(String(describing: error), privacy: .public)")
                    // Stop (no run, deadline or path monitor); show the refusal unless
                    // `admit` already stopped the service with its own text.
                    let show = !Task.isCancelled
                    self.shutdownConnection()
                    if show { store.markFailed(String(describing: error)) }
                    await connection.closeAndWait()
                    return
                }
                await self.observeRemote(connection)
                self.didConnect(connection, identity: identity)
                logger.info("\(machineID, privacy: .public): cmux-tui \(identity.version, privacy: .public) session \(identity.session, privacy: .public)")
                await store.run(connection: connection, scheduler: drainScheduler)
                await connection.closeAndWait()
                if Task.isCancelled { return }
                guard await ends.waitAfterFailure(wake: wake, clock: clock) else { return }
            }
        }
    }

    private func didConnect(_ connection: DaemonConnection, identity: DaemonIdentity) {
        Self.launchMark("daemon_connected")
        self.connection = connection
        let recovery = recovery
        connection.observeAnswering { [weak connection] answering in
            // task-owner: one hop to main per heartbeat edge or unanswered ask; nothing to cancel. On main it reads the
            // connection's answering again, so hops that land out of order never leave a stale state; an unanswered
            // ask that still holds probes the owner once more.
            Task { @MainActor in
                guard let connection else { return }
                let now = connection.daemonAnswering
                if now == answering || now { recovery.noteDaemonAnswering(now) }
            }
        }
        recovery.noteDaemonAnswering(connection.daemonAnswering)
        rememberLaunchSnapshot(identity)
        resumeConnectionWaiters()
        store.noteHandshake(identity)
        startupDeadlineTimer?.cancel()
        startupDeadlineTimer = nil
        lastStartupError = nil
        startup = .connected
        pushTerminalDefaultColors()
        relaunchKeptLayoutIfNeeded(connection)
    }

    /// Records a failed connect attempt (`DaemonStartupState.showsFailure`): unavailable after the deadline, or at once when no retry can help.
    func noteStartupFailure(_ error: DaemonError, retries: Bool = true) {
        logger.error("cmux-tui daemon unavailable: \(error.description, privacy: .public)")
        lastStartupError = error
        if startup.showsFailure(error, retries: retries) { store.markFailed(error.description) }
        if startup.isUnavailable || DaemonStartup.shared.isPermanent(error) || !retries {
            startup = .unavailable(error)
            resumeConnectionWaiters()
        }
    }

    /// The handshake handed an incompatible owner off to the bundled build
    /// (`DaemonLauncher.handOffIncompatible`); the next connect reaches its successor.
    /// The handoff can come after the first deadline already showed a failure, so the
    /// successor gets a fresh `.connecting` window and the old failure is dropped.
    func noteIncompatibleOwnerHandoff() {
        Self.launchMark("daemon_version_handoff")
        logger.info("cmux-tui daemon handoff: the running owner is incompatible; starting the bundled build")
        if startup != .connected {
            startup = .connecting
            lastStartupError = nil
        }
        armStartupDeadline()
    }

    func armStartupDeadline() {
        startupDeadlineTimer?.cancel()
        let timer = DemandTimer(owner: "DaemonService.startupDeadline", clock: startupClock)
        startupDeadlineTimer = timer
        timer.schedule(after: startupDeadline) { @MainActor [weak self] in
            guard let self, self.startup == .connecting else { return }
            if let error = self.lastStartupError { self.store.markFailed(error.description) }
            self.startup = .unavailable(self.lastStartupError ?? .timedOut("first connection to cmux-tui"))
            self.resumeConnectionWaiters()
        }
    }

    /// True once `start` began connecting.
    public var isStarting: Bool { runTask != nil }

    /// Runs a command and logs a failure. Returns false when it threw.
    @discardableResult
    public func run(_ label: String, _ body: DaemonCommandBody) async -> Bool {
        await failure(label, ticket: openTicket(label), body) == nil
    }

    /// Outcome of a command whose reply may miss its deadline.
    enum CommandOutcome {
        case succeeded
        /// The daemon refused or failed it; `code` is its `error_code` when it gave one.
        case failed(code: String?)
        /// The deadline passed: the daemon may still apply the command.
        case unknown
    }

    /// Like ``run(_:_:)``, but tells a deadline miss (outcome unknown) apart
    /// from a failure, so callers can reconcile instead of reverting.
    func runReportingTimeout(_ label: String, _ body: DaemonCommandBody) async -> CommandOutcome {
        let ticket = openTicket(label)
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            await closeTicket(ticket, label: label, error: DaemonError.notConnected)
            return .failed(code: nil)
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
            if case DaemonError.command(_, _, let code, _, _) = error { return .failed(code: code) }
            return .failed(code: nil)
        }
    }

    /// Fire-and-forget variant for UI handlers.
    public func send(_ label: String, _ body: @escaping DaemonCommandBody) {
        // Always start the task; `workTracker?(Task {...})` would skip
        // creating it (and drop the command) when no tracker is set.
        // The ticket opens now, so an action that awaits its scope waits
        // for this command even before the task starts.
        let ticket = openTicket(label)
        let task = Task { await failure(label, ticket: ticket, body) }
        workTracker?(task)
    }

    /// `send` that also hands a failure to `onFailure` (on the main actor),
    /// with the same ticket and work tracking.
    public func send(_ label: String, onFailure: @escaping @MainActor (ActionWorkFailure) -> Void,
              _ body: @escaping DaemonCommandBody) {
        let ticket = openTicket(label)
        let task = Task {
            let failed = await failure(label, ticket: ticket, body)
            if let failed { onFailure(failed) }
            return failed
        }
        workTracker?(task)
    }

    /// Runs a command; returns nil on success, else the failure (logged).
    public func failure(_ label: String, _ body: DaemonCommandBody) async -> ActionWorkFailure? {
        await failure(label, ticket: openTicket(label), body)
    }

    func failure(_ label: String, ticket: CommandTicket?,
                         _ body: DaemonCommandBody) async -> ActionWorkFailure? {
        guard let connection else {
            logger.error("\(label, privacy: .public): not connected")
            await closeTicket(ticket, label: label, error: DaemonError.notConnected)
            return "\(label): \(notConnectedReason ?? DaemonError.notConnected.description)"
        }
        do {
            try await body(connection)
            await closeTicket(ticket, label: label, error: nil, replying: connection)
            return nil
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await closeTicket(ticket, label: label, error: error)
            return workFailure(label, error)
        }
    }

    /// Receives every command task `send` starts, so an action run from the
    /// control socket can await it (`ActionRegistry.track`).
    @ObservationIgnored public var workTracker: ((ActionWork) -> Void)?
    /// Shows a request refused because it names a pane still opening (``PaneNotReady``) when no open action scope
    /// answers it; the app sets it (the refusal path: log + HUD). Gets the localized reason.
    @ObservationIgnored public var onPaneNotReady: ((_ reason: String) -> Void)?

    /// What each connection calls when it refuses a request that names a pane still opening, from any sender
    /// (`DaemonConnection.observePaneNotReady`): the notice shows on the next frame (the drain batcher: work a person's
    /// action caused), once.
    /// The service stays on the main actor: the hook carries only a main-actor closure (Sendable because it runs
    /// there), never the service itself.
    var paneNotReadyReporter: @Sendable (PaneNotReady) -> Void {
        let batcher = drainScheduler
        let show: @MainActor @Sendable (PaneNotReady) -> Void = { [weak self] notReady in self?.showPaneNotReady(notReady) }
        return { notReady in batcher.scheduleFrame { show(notReady) } }
    }

    private func showPaneNotReady(_ notReady: PaneNotReady) {
        #if DEBUG || CMUX_BENCH_HOOKS
        paneNotReadyCauses = Array((paneNotReadyCauses + [notReady.description]).suffix(100)) // as RefusalHUD.history
        #endif
        onPaneNotReady?(paneNotReadyText?() ?? notReady.reason)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Debug and bench builds: the command and stand-in reference of each ``PaneNotReady`` shown so far, newest last
    /// (`debug.toast` `pane_not_ready`). The person's toast says only "still opening"; this says which request named
    /// which pane, so a journey finds the sender. As many entries as the refusal HUD's own history.
    @ObservationIgnored public private(set) var paneNotReadyCauses: [String] = []
    #endif

    /// ``PaneNotReady``'s text in the app's language (the app sets it; its string catalog). Nil: the English text.
    @ObservationIgnored public var paneNotReadyText: (() -> String)?

    /// The failure of command `label` as the person reads it: ``PaneNotReady`` as a typed refusal in the app's language.
    public func workFailure(_ label: String, _ error: any Error) -> ActionWorkFailure {
        var failure = ActionWorkFailure(label, error)
        if error is PaneNotReady, let text = paneNotReadyText?() { failure.message = text }
        return failure
    }

    /// Teardown that must finish before the caller removes a test session's state or reaps its owner.
    public func shutdownConnectionAndWait() async {
        let startup = runTask
        let connected = detachConnection()
        await connected?.closeAndWait()
        await startup?.value
    }

    public func shutdownConnection() {
        // task-owner: teardown hop; close() is idempotent and finishes the store pump
        if let connection = detachConnection() { Task { await connection.close() } }
    }

    private func detachConnection() -> DaemonConnection? {
        // Nothing may start an owner again behind the shutdown (the unresponsive owner's restart).
        recovery.detach()
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
        let connected = connection
        connection = nil
        return connected
    }
}
