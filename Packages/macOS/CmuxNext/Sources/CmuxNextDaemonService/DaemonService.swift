import AppKit
public import CmuxNextActions
public import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
public import CmuxNextControl
public import CmuxNextDaemon
public import CmuxNextTrace
public import CmuxNextWakeups
import Foundation
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
    /// Where this machine's daemon connections count their wire traffic (``DaemonWireStats``,
    /// `debug.daemon.wire`): the app's recorder in Debug and bench builds and opted-in release
    /// builds, else nil.
    let wireStats: DaemonWireStats?
    public let store: DaemonStore
    /// Set while an administrator turned this machine's feature off: no endpoint, no re-attach.
    public let policyBlock = PolicyBlock()
    /// Retry Now and Restart cmux-tui while the local daemon cannot be reached (cx-jniyz.1).
    public let recovery = DaemonRecovery()
    public internal(set) var connection: DaemonConnection?
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
    /// What a person sees, which each connection's heartbeat follows (``ConnectionPresence``); nil
    /// counts the app as shown.
    @ObservationIgnored public var connectionPresence: ConnectionPresence? {
        didSet { if let connectionPresence, let connection { connection.heartbeat.follow(connectionPresence) } }
    }
    /// The app's Energy Saver the local daemon follows (DaemonService+Energy); nil until `follow(_:on:)`.
    @ObservationIgnored var energyFollow: DaemonEnergyFollow?
    /// Tells the local daemon which tabs this app shows (FrontendVisibilityReporter); nil until `reportFrontendVisibility(on:)`.
    @ObservationIgnored var frontendVisibility: FrontendVisibilityReporter?
    @ObservationIgnored var featureHello: DaemonFeatureHello?  // the local hellos' features (`start`); settled at the first connection
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
    /// The app's main-thread scheduler: a person-scope command's reply settles on it as
    /// userBlocking work (``settleReply(_:)``).
    public let mainWork: MainWorkScheduler
    /// The app's one deadline placer (the startup deadline, the update restart's bound, the store's
    /// deadlines). A remote machine's service gets the local one's (the Cloud, SSH and server services read it here).
    public let deadlines: MainDeadlineScheduler
    /// The app's one ``AppEvents`` (the activation that wakes a retry); a remote machine's service gets the
    /// local one's.
    public let appEvents: AppEvents
    @ObservationIgnored public let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")
    /// The local daemon's launch snapshot, read off main and drawn before the first connection (``DaemonLaunchSnapshot``).
    @ObservationIgnored public let launchSnapshot: DaemonLaunchSnapshot
    /// Callers of `endpoint()` waiting for the first connection (terminals
    /// drawn from the launch snapshot attach as soon as it exists).
    @ObservationIgnored var connectionWaiters: [OnceContinuation<Void, OnceContinuationError>] = []
    /// Watches each line the service's connections and its terminal attachments read (their reader threads'
    /// `daemon.line` scopes); nil watches nothing.
    @ObservationIgnored public let hangWatch: (any HangWatchScoping)?
    /// The local daemon's diagnostic sites (`server-diagnostic-site`), each once per daemon life across this
    /// service's connections; the app's hang reports install their sink here (`WatchdogReporting`), whose
    /// ledger keeps them once across app launches.
    @ObservationIgnored public let diagnosticSites = DaemonDiagnosticSiteRelay<DaemonDiagnosticSite.Sighting>()

    /// - Parameters:
    ///   - machineID: `local`, or the remote machine's id.
    ///   - echoesPlacementShift: The App passes `SidebarMirror.isLinked`; tests leave it off.
    ///   - mainWork: The app's main-thread scheduler (``MainWorkScheduler``), built at its composition
    ///     root and passed by init; a remote machine's service gets the same one (one main thread, one
    ///     budget). The service drains its store on a batcher it builds on it and settles person-scope
    ///     replies on it (a test passes one it ticks by hand).
    ///   - wireStats: Where its connections count their wire traffic; the app's composition root passes
    ///     its recorder (nil in a release build without field data opt-in, which counts nothing).
    ///   - hangWatch: The app's ``HangWatch`` from its composition root, for every connection and terminal
    ///     attachment this service opens; nil (tests) watches nothing.
    ///   - crashKeys: The app's crash keys, for the local daemon's service only: its store names its connection
    ///     epoch there (``DaemonStore/init(waitDeadlines:deadlines:causes:crashKeys:)``).
    ///   - deadlines: The app's one ``MainDeadlineScheduler`` on `mainWork` (`AppServices.mainDeadlines`), shared
    ///     by every service: one wake-up queue and one aligned grid for the main thread.
    ///   - appEvents: The app's one ``AppEvents`` (`AppServices.appEvents`), shared by every service: one
    ///     observer per notice for the app.
    public init(machineID: String = "local", echoesPlacementShift: Bool = false, mainWork: MainWorkScheduler,
                wireStats: DaemonWireStats? = nil, hangWatch: (any HangWatchScoping)? = nil, crashKeys: CrashKeySlots? = nil,
                deadlines: MainDeadlineScheduler, appEvents: AppEvents) {
        self.machineID = machineID
        self.echoesPlacementShift = echoesPlacementShift
        // Its keyed waits' timeouts share the main thread's one deadline timer.
        store = DaemonStore(waitDeadlines: mainWork.wakeUps, deadlines: deadlines, causes: mainWork.causes, crashKeys: crashKeys)
        self.wireStats = wireStats
        self.hangWatch = hangWatch
        drainScheduler = FrameBatcher(owner: "DaemonStore.drain", scheduler: mainWork.frames)
        self.mainWork = mainWork
        self.deadlines = deadlines
        self.appEvents = appEvents
        launchSnapshot = DaemonLaunchSnapshot(store: store, mainWork: mainWork)
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
    private nonisolated static let launchMarkSink = Mutex<@Sendable (String) -> Void>({ _ in })

    /// Fires `retryWake` when the app becomes active (an ``AppEvents`` subscription: one observer for the app),
    /// and asks the heartbeat once (``becameActive()``).
    private func observeRetryEvents() {
        guard activationWatch == nil else { return }
        let wake = retryWake
        let mainWork = mainWork
        activationWatch = appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: "DaemonService.retryWake") { [weak self] in
            wake.fire()
            let service = self
            mainWork.postFromAnyThread(.background, owner: "DaemonService.activation") { service?.becameActive() }
        }
    }

    /// The app became active: with the App's presence the connection's heartbeat asks once.
    private func becameActive() {
        guard connectionPresence != nil else { return }
        connection?.heartbeat.activated()
    }

    /// How the first connection is going (window connecting state, control
    /// errors). Becomes `.unavailable` after `startupDeadline` or on an
    /// incompatible daemon; retrying continues in the background.
    public private(set) var startup: DaemonStartupState = .connecting
    /// Whether the launch connect attached a daemon that kept running while the app was gone (``DaemonLaunchAttach``);
    /// `.reattached` also marks the launch `daemon_reattached`.
    public private(set) var launchAttach: DaemonLaunchAttach = .pending
    @ObservationIgnored var startupDeadline: Duration = DaemonStartup.shared.defaultDeadline
    @ObservationIgnored var startupClock: any Clock<Duration> = ContinuousClock()
    @ObservationIgnored private var startupDeadlineTimer: MainDeadline?
    /// The last failed connect attempt until a connection succeeds (`notConnectedReason`).
    @ObservationIgnored private(set) var lastStartupError: DaemonError?
    /// Events that may let a failed connect succeed: the daemon socket
    /// changing (watched by the connection), the app becoming active, and
    /// for a Cloud machine a network path change. Retries past their timed
    /// budget wait only for these (no polling).
    @ObservationIgnored public private(set) var retryWake: RetryWake
    @ObservationIgnored private var activationWatch: EventSubscription?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
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

    /// `terminalEnvironment` (`AppEnvironment.terminalEnvironment`), with `resolvedTerminalEnvironment` over it,
    /// goes to the daemon process and to every terminal it creates for this app. `prestart` is the first connect attempt `main` began
    /// (`DaemonService.prestart`); without one the first attempt starts here, its launcher's disk steps on
    /// `work` (the app's one ``BackgroundWork``). `team`: this process's Team ID, as the prestart got it.
    /// `launchSnapshot` is the snapshot's read `main` began; without one
    /// the read is posted to `work` here (``DaemonLaunchSnapshot/take(_:session:stateDirectory:work:)``).
    /// `featureHello`: the app's daemon features for every hello. `terminalStreams`: as in `localConfiguration`.
    public func start(work: BackgroundWork, launch: LaunchIdentity, team: String?, terminalEnvironment: [String: String],
               resolvedTerminalEnvironment: (@Sendable () async -> [String: String])? = nil,
               terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String],
               resolvesShellIntegration: Bool = false, terminalStreams: TerminalStreamsDevice? = nil,
               prestart: DaemonPrestart? = nil, launchSnapshot: LaunchSnapshotPrefetch? = nil,
               featureHello: DaemonFeatureHello? = nil) {
        guard runTask == nil else { return }
        self.featureHello = prestart?.featureHello ?? featureHello
        let launcher: DaemonLauncher
        if let prestart {
            launcher = prestart.launcher
            retryWake = prestart.wake
        } else {
            do {
                launcher = try DaemonLauncher.forApp(work: work, build: launch.build, team: team,
                                                terminalEnvironment: terminalEnvironment,
                                                resolvedTerminalEnvironment: resolvedTerminalEnvironment,
                                                daemonEnvironment: Self.firstPartyAppsEnvironment, webSocketPageOrigins: Self.pageOrigins,
                                                wireStats: wireStats)
            } catch {
                noteStartupFailure((error as? DaemonError) ?? .launchFailed(String(describing: error)))
                self.featureHello?.settle()  // no daemon will answer this launch's hello
                return
            }
        }
        endpointProvider = launcher.endpointProvider
        recovery.attach(launcher, wake: retryWake, on: mainWork)
        // Before the first connection the retry loop has no socket watch of its own (the connection installs one
        // after its first handshake): watch the socket the last launch used and its ready marker, so a daemon
        // that finishes a long restore or handoff wakes a loop past its timed budget (cx-4bd8m).
        if let socket = launcher.configuration.rememberedSocket {
            retryWake.watch(file: socket, companions: [socket + ".websocket.json"])
        }
        pageListenerHandOff = { await launcher.handOffForCapability(DaemonCapability.wsListen.rawValue, identity: $1, using: $0) }
        updateHandOff = { await launcher.handOffForUpdate(identity: $1, using: $0) }
        self.launchSnapshot.take(launchSnapshot, session: launcher.configuration.session, stateDirectory: launcher.configuration.stateDirectory, work: work)
        let configuration = Self.localConfiguration(terminalEnvironment: terminalEnvironmentProvider,
                                                    resolvesShellIntegration: resolvesShellIntegration,
                                                    installKey: launcher.configuration.installKey,
                                                    echoesPlacementShift: echoesPlacementShift, retryWake: retryWake,
                                                    hangWatch: hangWatch, featureHello: self.featureHello,
                                                    terminalStreams: terminalStreams)
        // The launch's connect milestones: the prestart's, or this start's first attempt's when there is none.
        let marks = prestart?.marks ?? Self.launchConnectMarks()
        marks.mark(.connectStarted)
        var first: (@Sendable () async -> DaemonPrestart.Outcome)?
        if let prestart {
            // Cancelling the startup (shutdown) cancels the attempt too.
            first = { @Sendable in
                await withTaskCancellationHandler { await prestart.outcome() } onCancel: { prestart.cancel() }
            }
        }
        // After an update the daemon may still be the previous build's: hand
        // it off to the bundled build before attaching; terminals survive
        // (their hosts are adopted by the new daemon). The bundled build's
        // commit is read while the first connect runs, off its path.
        let logger = logger
        // task-owner: one `--version` run per start; the handoff check awaits it. Off main: the run's process
        // wait never resumes on the main actor.
        let bundledCommit = prestart?.bundledCommit ?? Task { @concurrent in try? await launcher.bundledBuildCommit() }
        let handOff: @Sendable (DaemonConnection, DaemonIdentity) async -> Bool = { connection, identity in
            guard identity.buildCommit != nil, let bundled = await bundledCommit.value else { return false }
            let decision = await launcher.handOffIfStale(identity: identity, using: connection, bundledCommit: bundled)
            guard case .restart(let running, let target) = decision else { return false }
            DaemonService.launchMark("daemon_version_handoff")
            logger.info("daemon handoff \(running, privacy: .public) -> \(target, privacy: .public)")
            return true
        }
        start(first: first, handOff: handOff, marks: marks) {
            DaemonConnection(configuration: configuration, endpointProvider: marks.endpointProvider(of: launcher))
        }
    }

    /// Connects with `makeConnection`, retrying the first connect until it
    /// succeeds (`DaemonStartup`), then mirrors the connection into `store`.
    /// The connection reconnects by itself afterwards. `handOff` runs before
    /// the app attaches; true means the daemon is exiting for a version
    /// handoff, so the app connects again and attaches to its successor only.
    /// `marks` (the launch's connect milestones) attaches the connection the app runs, and closes when the startup
    /// gives up.
    public func start(first: (@Sendable () async -> DaemonPrestart.Outcome)? = nil,
               handOff: (@Sendable (DaemonConnection, DaemonIdentity) async -> Bool)? = nil,
               marks: DaemonConnectMarks? = nil,
               makeConnection: @escaping @Sendable () -> DaemonConnection) {
        guard runTask == nil else { return }
        let store = store
        armStartupDeadline()
        observeRetryEvents()
        let wake = retryWake, clock = startupClock
        // task-owner: the first connection's lifecycle (`runTask`); shutdownConnection cancels it. Off main: it awaits
        // the connect, the handoff and the store's run; its steps on main are this service's main-actor methods
        // (`armStartupDeadline`, `attachConnection`) and the store's run (recipe R-hop).
        runTask = Task { @concurrent [weak self, drainScheduler] in
            weak let weakSelf = self
            let onFailure: @Sendable (DaemonError) async -> Void = { error in await weakSelf?.noteStartupFailure(error) }
            var connected = await DaemonStartup.shared.connect(wake: wake, clock: clock, first: first,
                                                               makeConnection: makeConnection, onFailure: onFailure)
            if let (exiting, identity) = connected, let handOff, await handOff(exiting, identity) {
                // The new connection's endpoint waits for the old daemon to
                // exit and starts the bundled build, which adopts the terminals.
                await exiting.close()
                // The first connect was in time; the deadline now covers
                // the successor's start.
                await self?.armStartupDeadline()
                connected = nil
                if !Task.isCancelled {
                    connected = await DaemonStartup.shared.connect(wake: wake, clock: clock, makeConnection: makeConnection,
                                                                   onFailure: onFailure)
                }
            }
            guard let (connection, identity) = connected else {
                marks?.close()
                return
            }
            guard let self, !Task.isCancelled else {
                marks?.close()
                await connection.close()
                return
            }
            await marks?.attach(connection)
            await self.attachConnection(connection, identity: identity, launchStartedDaemon: marks?.startedDaemon)
            await store.run(connection: connection, scheduler: drainScheduler)
        }
    }

    /// The first connection's handshake: it becomes the connection this service runs. `launchStartedDaemon` is the
    /// launch marks' answer (nil without marks): noted on main before the connection attaches.
    private func attachConnection(_ connection: DaemonConnection, identity: DaemonIdentity, launchStartedDaemon: Bool?) {
        if let launchStartedDaemon { noteLaunchAttach(startedDaemon: launchStartedDaemon) }
        didConnect(connection, identity: identity)
        windowState = WindowStateStore(connection: connection)
        logger.info("cmux-tui \(identity.version, privacy: .public) session \(identity.session, privacy: .public)")
        rememberSocket(identity, connection: connection)
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
        let wireStats = wireStats
        remoteEndpoint = { DaemonEndpoint(socketPath: try await endpoint(), wireStats: wireStats) }
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
        monitor.start(queue: DispatchQueue(label: "com.cmuxterm.next.daemon.path.\(machineID)", qos: .utility))
        pathMonitor = monitor
        let clock = startupClock
        var configuration = DaemonConnection.Configuration(retryWake: wake, terminalEnvironment: nil, sessionEvents: true)
        configuration.echoesPlacementShift = echoesPlacementShift
        configuration.hangWatch = hangWatch
        // task-owner: the remote machine's connection lifecycle (`runTask`); shutdownConnection cancels it. Off main:
        // it awaits each connect, the store's run and the backoff; its step on main per connection is
        // `admitConnection` (recipe R-hop).
        runTask = Task { @concurrent [weak self, drainScheduler, logger, configuration] in
            weak let weakSelf = self
            var ends = RetryPacer(.firstConnect)
            // wakeup-allow: backoff: each iteration runs a connection to its end, then waits in RetryPacer
            while !Task.isCancelled {
                let connected = await DaemonStartup.shared.connect(wake: wake, clock: clock) {
                    DaemonConnection(configuration: configuration) {
                        DaemonEndpoint(socketPath: try await endpoint(), bridge: bridge, wireStats: wireStats)
                    }
                } onFailure: { error in
                    logger.error("\(machineID, privacy: .public): daemon unavailable: \(error.description, privacy: .public)")
                    // Before the failure is published: an event from then on
                    // (the machine updated, app activation) wakes the wait below.
                    if DaemonStartup.shared.isPermanent(error) { wake.rebaseline() }
                    await weakSelf?.noteStartupFailure(error)
                }
                if Task.isCancelled {
                    await connected?.0.close()
                    return
                }
                guard let (connection, identity) = connected else {
                    // Incompatible daemon: wait for an event only, then try again.
                    guard await wake.awaitWake(delay: nil, clock: clock) != .cancelled else { return }
                    continue
                }
                guard let self, !Task.isCancelled else {
                    await connection.close()
                    return
                }
                guard await self.admitConnection(connection, identity: identity, admit: admit) else {
                    await connection.close()
                    return
                }
                await store.run(connection: connection, scheduler: drainScheduler)
                await connection.close()
                if Task.isCancelled { return }
                guard await ends.waitAfterFailure(wake: wake, clock: clock) else { return }
            }
        }
    }

    /// A remote connection's handshake: `admit` checks its identity first. A refusal stops the service and shows why
    /// (unless `admit` stopped it with its own text); true when the connection is the one this service runs now.
    /// Runs in the lifecycle's task, so `Task.isCancelled` is that task's.
    private func admitConnection(_ connection: DaemonConnection, identity: DaemonIdentity,
                                 admit: (@MainActor (DaemonIdentity) throws -> Void)?) -> Bool {
        do {
            try admit?(identity)
        } catch {
            logger.error("\(self.machineID, privacy: .public): refused the daemon after the handshake: \(String(describing: error), privacy: .public)")
            // Stop (no run, deadline or path monitor); show the refusal unless
            // `admit` already stopped the service with its own text.
            let show = !Task.isCancelled
            shutdownConnection()
            if show { store.markFailed(String(describing: error)) }
            return false
        }
        didConnect(connection, identity: identity)
        logger.info("\(self.machineID, privacy: .public): cmux-tui \(identity.version, privacy: .public) session \(identity.session, privacy: .public)")
        return true
    }

    private func didConnect(_ connection: DaemonConnection, identity: DaemonIdentity) {
        Self.launchMark("daemon_connected")
        connection.heartbeat.follow(KeepaliveGate(mainWork.energy))
        if let connectionPresence { connection.heartbeat.follow(connectionPresence) }
        self.connection = connection
        connection.diagnosticSites.forward(to: diagnosticSites)
        launchSnapshot.remember(identity)
        resumeConnectionWaiters()
        store.noteHandshake(identity)
        startupDeadlineTimer?.cancel()
        startupDeadlineTimer = nil
        lastStartupError = nil
        startup = .connected
        pushTerminalDefaultColors()
        relaunchKeptLayoutIfNeeded(connection)
    }

    /// The launch connect attached its connection: the daemon was running before this launch unless an attempt started
    /// it (cold, or the handoff's successor). Once per service.
    private func noteLaunchAttach(startedDaemon: Bool) {
        guard launchAttach == .pending else { return }
        launchAttach = startedDaemon ? .started : .reattached
        if launchAttach == .reattached { Self.launchMark("daemon_reattached") }
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

    /// The first connection's deadline: a visible deadline (the window shows the failure), flexible (no sooner).
    private func armStartupDeadline() {
        startupDeadlineTimer?.cancel()
        let timer = startupDeadlineTimer ?? MainDeadline(owner: "DaemonService.startupDeadline", workClass: .visible, scheduler: deadlines)
        startupDeadlineTimer = timer
        timer.schedule(after: startupDeadline) { [weak self] in
            guard let self, self.startup == .connecting else { return }
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
        // Always start the task; making it inside `workTracker?(...)` would
        // skip creating it (and drop the command) when no tracker is set.
        // The ticket opens now, so an action that awaits its scope waits
        // for this command even before the task starts.
        // The command runs off main; its failure is made on main in the sender's class (`startSend`).
        workTracker?(startSend(label, onFailure: nil, body))
    }

    /// `send` that also hands a failure to `onFailure` (on the main actor),
    /// with the same ticket and work tracking.
    public func send(_ label: String, onFailure: @escaping @MainActor (ActionWorkFailure) -> Void,
              _ body: @escaping DaemonCommandBody) {
        workTracker?(startSend(label, onFailure: onFailure, body))
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
            return ActionWorkFailure(label, error)
        }
    }

    /// Receives every command task `send` starts, so an action run from the
    /// control socket can await it (`ActionRegistry.track`).
    @ObservationIgnored public var workTracker: ((ActionWork) -> Void)?

    public func shutdownConnection() {
        startupDeadlineTimer?.cancel()
        startupDeadlineTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        activationWatch = nil
        runTask?.cancel()
        runTask = nil
        keptLayoutRelaunch?.cancel()
        keptLayoutRelaunch = nil
        // task-owner: teardown; close() is idempotent and finishes the store pump. Off main: nothing resumes here.
        if let connection { Task { @concurrent in await connection.close() } }
        connection = nil
    }
}
