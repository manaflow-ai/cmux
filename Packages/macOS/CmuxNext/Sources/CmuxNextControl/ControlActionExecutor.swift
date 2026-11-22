public import CmuxNextSettings

/// Runs actions for `action.run`. The router calls it on the main actor
/// through ``MainActorWorkQueue`` after validating the request off-main, so
/// an implementation must be synchronous and short: apply local state, send
/// daemon commands without awaiting their replies, return. The App's
/// implementation is `RegistryControlBridge`; tests inject a fake.
public protocol ControlActionExecutor: Sendable {
    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome
    /// Like `performAction`, plus the daemon work the handler started, so
    /// a caller can answer after the effect exists (cmux CLI compat).
    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun
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
    /// The app bundle, and its bundled `cmux` CLI when that is executable.
    /// Reported under the old app's keys (`app_bundle_path`,
    /// `app_cli_path`) so a CLI that reached this socket by mistake can
    /// name the CLI that matches this app.
    public var appBundlePath: String?
    public var appCLIPath: String?

    public init(appName: String = "cmux-next", version: String, build: String, bundleID: String?, tag: String?, processID: Int32,
                appBundlePath: String? = nil, appCLIPath: String? = nil) {
        self.appName = appName
        self.version = version
        self.build = build
        self.bundleID = bundleID
        self.tag = tag
        self.processID = processID
        self.appBundlePath = appBundlePath
        self.appCLIPath = appCLIPath
    }
}
