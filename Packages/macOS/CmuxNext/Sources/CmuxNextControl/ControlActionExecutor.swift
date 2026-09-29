public import CmuxNextSettings

/// Runs actions for `action.run`. The App's implementation
/// (`RegistryControlBridge`) hops to the main actor and calls
/// `ActionRegistry.perform`; tests inject a fake.
public protocol ControlActionExecutor: Sendable {
    func runAction(_ request: ControlActionRequest) async -> ControlActionOutcome
}

/// `settings.get` / `settings.set` storage. `CmuxConfigFile` conforms, so
/// writes land in cmux.json and the settings watcher applies them.
public protocol ControlSettingsStore: Sendable {
    func value(at path: [String]) async throws -> JSONValue?
    func set(_ value: JSONValue, at path: [String]) async throws
    func remove(_ path: [String]) async throws
    var fileLocation: String { get }
}

extension CmuxConfigFile: ControlSettingsStore {
    public nonisolated var fileLocation: String { url.path }
}

/// Facts `system.identify` reports about the running app.
public struct ControlIdentity: Sendable {
    public var appName: String
    public var version: String
    public var build: String
    public var bundleID: String?
    public var tag: String?
    public var processID: Int32

    public init(appName: String = "cmux-next", version: String, build: String, bundleID: String?, tag: String?, processID: Int32) {
        self.appName = appName
        self.version = version
        self.build = build
        self.bundleID = bundleID
        self.tag = tag
        self.processID = processID
    }
}
