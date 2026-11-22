public import Foundation

/// Everything one app's engine needs.
public nonisolated struct AppEngineConfiguration: Sendable {
    public var manifest: AppManifest
    /// The unpacked bundle (holds `cmux-app.json` and `main`).
    public var bundleDirectory: URL
    /// Scopes the user granted and the sandbox switch, read per call.
    public var grants: AppGrants
    /// `cmux.app.settings()`: manifest defaults overlaid with the user's values.
    public var settings: AppJSON
    public var sink: any AppOperationSink
    public var events: AppEventHub
    public var clock: any AppEngineClock
    public var scopes: AppScopeTable
    public var runtimeScript: URL
    /// Limits per VM (spec 5.2).
    public var evaluationLimit: Duration = AppWatchdog.defaultLimit
    public var maxPendingCalls = 64
    public var maxTimers = 200
    public var output: @Sendable (AppEngineOutput) -> Void

    public init(manifest: AppManifest, bundleDirectory: URL, grants: AppGrants, settings: AppJSON? = nil,
                sink: any AppOperationSink, events: AppEventHub = AppEventHub(), clock: any AppEngineClock = ContinuousAppEngineClock(),
                scopes: AppScopeTable = .bundled, runtimeScript: URL = AppPlatformResources.runtimeScript,
                output: @escaping @Sendable (AppEngineOutput) -> Void) {
        self.manifest = manifest
        self.bundleDirectory = bundleDirectory
        self.grants = grants
        self.settings = settings ?? .object(manifest.contributes.settingsDefaults)
        self.sink = sink
        self.events = events
        self.clock = clock
        self.scopes = scopes
        self.runtimeScript = runtimeScript
        self.output = output
    }
}

/// Why an engine refused to start or an entry point failed.
public nonisolated struct AppEngineError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
