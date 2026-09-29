public import CmuxNextActions
public import CmuxNextSettings
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
/// `CMUX_NEXT_SOCKET_PATH`). Inherited `CMUX_*` variables never choose it.
/// Access mode: `CMUX_NEXT_SOCKET_MODE`, else cmux.json
/// `automation.socketControlMode`, else `cmuxOnly`. Password mode checks
/// `CMUX_NEXT_SOCKET_PASSWORD` unless the App passes its own verifier.
@MainActor
public final class ControlService {
    public let server: ControlSocketServer
    public let router: ControlRouter
    public let bridge: RegistryControlBridge

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
        passwordVerifier: (@Sendable (String) -> Bool)? = nil,
        frameSource: any ControlFrameSource = MainQueueFrameSource(),
        watchdog: MainThreadWatchdog? = nil
    ) throws -> ControlService {
        let configuredMode = settings?.snapshot.root.value(at: ["automation", "socketControlMode"])?.stringValue
        let mode = explicitMode
            ?? environment["CMUX_NEXT_SOCKET_MODE"].flatMap(parseAccessMode)
            ?? configuredMode.flatMap(parseAccessMode)
            ?? .cmuxOnly
        var verifier = passwordVerifier
        if verifier == nil, let expected = environment["CMUX_NEXT_SOCKET_PASSWORD"], !expected.isEmpty {
            verifier = { @Sendable candidate in candidate == expected }
        }
        let identity = ControlIdentity(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            bundleID: launch.bundleID,
            tag: launch.tag,
            processID: getpid()
        )
        return try start(
            registry: registry,
            settingsStore: settings?.file,
            configuration: ControlSocketServer.Configuration(path: launch.socketPath, accessMode: mode, passwordVerifier: verifier),
            identity: identity,
            frameSource: frameSource,
            watchdog: watchdog
        )
    }

    /// Starts with an explicit configuration (tests, demos).
    public static func start(
        registry: ActionRegistry,
        settingsStore: (any ControlSettingsStore)?,
        configuration: ControlSocketServer.Configuration,
        identity: ControlIdentity,
        frameSource: any ControlFrameSource = MainQueueFrameSource(),
        watchdog: MainThreadWatchdog? = nil
    ) throws -> ControlService {
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: identity, executor: bridge, settings: settingsStore, frameSource: frameSource)
        router.attach(watchdog: watchdog)
        bridge.attach(to: router)
        let server = ControlSocketServer(configuration: configuration, router: router)
        try server.start()
        return ControlService(server: server, router: router, bridge: bridge)
    }

    public func stop() {
        server.stop()
        bridge.detach()
    }

    /// Maps cmux.json / environment mode strings, including the old app's
    /// legacy aliases.
    public nonisolated static func parseAccessMode(_ raw: String) -> ControlAccessMode? {
        switch raw.lowercased().filter({ $0.isLetter }) {
        case "off": .off
        case "cmuxonly": .cmuxOnly
        case "automation", "notifications": .automation
        case "password": .password
        case "allowall", "openaccess", "fullopenaccess", "full": .allowAll
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
}
