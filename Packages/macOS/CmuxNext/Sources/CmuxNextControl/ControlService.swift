public import CmuxNextActions
public import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextSettings
public import CmuxNextTrace
public import CmuxNextWakeups
public import Foundation

/// The App's one-call entry point for the control socket.
///
/// ```swift
/// // applicationDidFinishLaunching, after actions are bound:
/// settings = SettingsController(registry: registry)
/// settings.start()
/// control = try? ControlService.start(registry: registry, settings: settings)
/// // applicationWillTerminate:
/// control?.stop()
/// ```
///
/// Path: ``LaunchIdentity/socketPath`` (the bundle/tag convention, or
/// `CMUX_NEXT_SOCKET_PATH`), with a symlink at its old `/tmp` name. Inherited `CMUX_*` variables never choose it.
/// Access mode: `CMUX_NEXT_SOCKET_MODE`, else cmux.json
/// `automation.socketControlMode`, else `automation` (any process of this
/// user; see ``defaultAccessMode``). The retired password mode fails closed
/// to `off`; plaintext socket passwords are never read from settings or env.
///
/// Hang watch: with `hangs` (the app passes `TraceRuntime.shared.hangWatch`, which its hang monitor reads),
/// the accept queue and each connection's queue are hang-watched lanes, one scope per job
/// (``ControlSocketServer``); nil, the default, watches nothing.
@MainActor
public final class ControlService {
    public let server: ControlSocketServer
    public let router: ControlRouter
    public let bridge: RegistryControlBridge
    /// The router's idempotency cache in the app's memory coordinator (`control-idempotency`).
    private var memoryRegistration: AsyncMemoryConsumerRegistration?

    init(server: ControlSocketServer, router: ControlRouter, bridge: RegistryControlBridge) {
        self.server = server
        self.router = router
        self.bridge = bridge
    }

    public var socketPath: String { server.configuration.path }

    /// Resolves path and access mode, binds, and starts serving.
    public static func start(
        registry: ActionRegistry,
        settings: SettingsController?,
        launch: LaunchIdentity,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        accessMode explicitMode: ControlAccessMode? = nil,
        frameSource: any ControlFrameSource = MainQueueFrameSource(),
        watchdog: MainThreadWatchdog? = nil,
        mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
        hangs: (any HangWatchScoping)? = nil
    ) throws -> ControlService {
        let service = try prepare(registry: registry, settings: settings, launch: launch, environment: environment, bundle: bundle,
                                  accessMode: explicitMode, frameSource: frameSource, watchdog: watchdog, mainWork: mainWork,
                                  hangs: hangs)
        try service.server.start()
        return service
    }

    /// Resolves path and access mode and builds the router, which takes method registrations, but
    /// accepts no connection until ``serve(adopting:)``: a request never reaches a
    /// router whose methods are not all registered. Throws `disabled` when the mode is `off`.
    public static func prepare(
        registry: ActionRegistry,
        settings: SettingsController?,
        launch: LaunchIdentity,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        accessMode explicitMode: ControlAccessMode? = nil,
        frameSource: any ControlFrameSource = MainQueueFrameSource(),
        watchdog: MainThreadWatchdog? = nil,
        mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
        hangs: (any HangWatchScoping)? = nil
    ) throws -> ControlService {
        let configuredMode = settings?.snapshot.root.value(at: ["automation", "socketControlMode"])?.stringValue
        let mode = resolveAccessMode(explicit: explicitMode, environment: environment, configured: configuredMode)
        let identity = ControlIdentity(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            bundleID: launch.bundleID,
            tag: launch.tag,
            processID: getpid(),
            appBundlePath: bundle.bundleURL.path,
            appCLIPath: bundle.resourceURL.map { $0.appendingPathComponent("bin/cmux").path }
                .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        )
        return try prepare(
            registry: registry,
            settingsStore: settings?.file,
            settingsWriter: settings,
            configuration: ControlSocketServer.Configuration(path: launch.socketPath, accessMode: mode,
                                                             protectStateDirectory: protectsStateDirectory(launch),
                                                             trustedExecutables: bundledExecutables(bundle, environment: environment),
                                                             compatibilityLink: launch.compatibilityLink),
            identity: identity,
            frameSource: frameSource,
            watchdog: watchdog,
            mainWork: mainWork,
            hangs: hangs
        )
    }

    /// Starts with an explicit configuration (tests, demos).
    public static func start(
        registry: ActionRegistry,
        settingsStore: (any ControlSettingsStore)?,
        settingsWriter: (any ControlSettingsWriter)? = nil,
        configuration: ControlSocketServer.Configuration,
        identity: ControlIdentity,
        frameSource: any ControlFrameSource = MainQueueFrameSource(),
        watchdog: MainThreadWatchdog? = nil,
        mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
        hangs: (any HangWatchScoping)? = nil
    ) throws -> ControlService {
        let service = try prepare(registry: registry, settingsStore: settingsStore, settingsWriter: settingsWriter,
                                  configuration: configuration, identity: identity, frameSource: frameSource, watchdog: watchdog,
                                  mainWork: mainWork, hangs: hangs)
        try service.server.start()
        return service
    }

    /// ``prepare(registry:settings:launch:environment:bundle:accessMode:frameSource:watchdog:mainWork:hangs:)`` with an
    /// explicit configuration (tests, demos).
    public static func prepare(
        registry: ActionRegistry,
        settingsStore: (any ControlSettingsStore)?,
        settingsWriter: (any ControlSettingsWriter)? = nil,
        configuration: ControlSocketServer.Configuration,
        identity: ControlIdentity,
        frameSource: any ControlFrameSource = MainQueueFrameSource(),
        watchdog: MainThreadWatchdog? = nil,
        mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
        hangs: (any HangWatchScoping)? = nil
    ) throws -> ControlService {
        guard configuration.accessMode != .off else { throw ControlSocketServer.StartError.disabled }
        let bridge = RegistryControlBridge(registry: registry, work: mainWork)
        let router = ControlRouter(identity: identity, executor: bridge, settings: settingsStore, settingsWriter: settingsWriter,
                                   frameSource: frameSource)
        router.attach(watchdog: watchdog)
        #if DEBUG || CMUX_BENCH_HOOKS
        // Every thread's requested QoS against its declared row (threading-model.md).
        router.register([ThreadsControl().method])
        #endif
        bridge.attach(to: router)
        let server = ControlSocketServer(configuration: configuration, router: router, hangs: hangs)
        return ControlService(server: server, router: router, bridge: bridge)
    }

    /// Registers the router's idempotency cache with the app's memory coordinator
    /// (`control-idempotency`); the service keeps the registration, so the coordinator calls the cache
    /// while the service lives. A second call replaces the first.
    ///
    /// - Parameters:
    ///   - registry: The memory coordinator (AppServices+Memory.swift).
    ///   - hop: How the coordinator's calls leave the main actor (tests pass their own).
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry, hop: AsyncMemoryConsumerHop = .task) {
        memoryRegistration = AsyncMemoryConsumerRegistration(
            name: "control-idempotency", traits: ControlIdempotencyCache.memoryTraits, consumer: router.idempotency,
            registry: registry, hop: hop)
    }

    /// Starts accepting, once every method group is registered: on `listener` when the app bound it
    /// off the main thread (``ControlSocketBind``), else by binding now. Throws what
    /// ``ControlSocketServer/start()`` throws.
    public func serve(adopting listener: ControlSocketListener?) throws {
        if let listener { try server.start(adopting: listener) } else { try server.start() }
    }

    /// ``serve(adopting:)`` on `bind`'s listener once its bind finished (at once without a bind: this
    /// call binds). `done` gets the socket's path, or why it does not serve (another live instance owns
    /// the path, the bind failed).
    public func serve(after bind: ControlSocketBind?, _ done: @escaping @MainActor (Result<String, any Error>) -> Void) {
        guard let bind else { return done(serveResult(nil)) }
        bind.whenBound { [self] outcome in done(serveResult(outcome)) }
    }

    private func serveResult(_ outcome: ControlSocketBind.Outcome?) -> Result<String, any Error> {
        do {
            try serve(adopting: outcome?.get())
            return .success(socketPath)
        } catch {
            return .failure(error)
        }
    }

    public func stop() {
        server.stop()
        bridge.detach()
    }

    /// Binds the control socket again (Restart CLI Listener): open
    /// connections close; the router and its methods stay.
    public func restartListener() throws {
        try server.restart()
    }

    /// The mode when nothing chooses one. The socket file is 0600 in a
    /// directory only this user can read, so the kernel already limits it to
    /// this user; descent from the app adds no boundary and refuses this
    /// app's own terminals (their daemon is launchd's child) and agents run
    /// by other supervisors (acpmux). `cmuxOnly`, `password` and `off` stay
    /// available in cmux.json.
    public nonisolated static let defaultAccessMode: ControlAccessMode = .automation

    /// `explicit`, else `CMUX_NEXT_SOCKET_MODE`, else cmux.json, else the default.
    public nonisolated static func resolveAccessMode(
        explicit: ControlAccessMode?,
        environment: [String: String],
        configured: String?
    ) -> ControlAccessMode {
        explicit
            ?? environment["CMUX_NEXT_SOCKET_MODE"].flatMap(parseAccessMode)
            ?? configured.flatMap(parseAccessMode)
            ?? defaultAccessMode
    }

    /// Maps cmux.json / environment mode strings, including the old app's
    /// legacy aliases.
    public nonisolated static func parseAccessMode(_ raw: String) -> ControlAccessMode? {
        switch raw.lowercased().filter({ $0.isLetter }) {
        case "off": .off
        case "cmuxonly": .cmuxOnly
        case "automation", "notifications": .automation
        case "password": .off
        case "allowall", "openaccess", "fullopenaccess", "full": .automation
        default: nil
        }
    }

    public nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Whether `launch` names the canonical directory cmux owns, rather than an override parent.
    static func protectsStateDirectory(_ launch: LaunchIdentity) -> Bool {
        if launch.compatibilityLink != nil { return true }
        let parent = URL(fileURLWithPath: launch.socketPath).deletingLastPathComponent().standardizedFileURL.path
        return parent == ControlSocketPath.shared.stateDirectory()
    }

    /// The bundled cmux binary (`bin/cmux`, also run as `bin/cmux-tui`),
    /// whose processes host every terminal: `.cmuxOnly` admits their
    /// descendants. Includes the daemon binary the launcher resolves the
    /// same way (`CMUX_NEXT_TUI_BIN` in dev builds).
    static func bundledExecutables(_ bundle: Bundle, environment: [String: String]) -> Set<String> {
        var urls: [URL] = []
        if let bin = bundle.resourceURL?.appendingPathComponent("bin") {
            urls += ["cmux", "cmux-tui"].map { bin.appendingPathComponent($0) }
        }
        if let daemon = try? DaemonLauncher.resolveBinary(bundle: bundle, environment: environment) { urls.append(daemon) }
        return Set(urls.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] })
    }
}
