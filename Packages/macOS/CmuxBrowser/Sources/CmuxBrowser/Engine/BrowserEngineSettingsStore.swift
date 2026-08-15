@preconcurrency public import Foundation

/// Reads and writes the persisted defaults used when a browser pane is created.
///
/// The store owns no global state: callers inject the `UserDefaults` suite at
/// the composition boundary, and tests can use an isolated suite. Existing
/// panes retain the values captured at creation time.
public struct BrowserEngineSettingsStore: Sendable {
    /// The `UserDefaults` key for the engine used by newly created panes.
    public static let defaultEngineKey = "browser.defaultEngine"

    /// The `UserDefaults` key for the optional loopback CDP listener.
    public static let remoteDebuggingPortKey = "browser.remoteDebuggingPort"

    /// The fail-closed engine used when no preference has been persisted.
    public static let defaultEngine: BrowserEngineKind = .webkit

    /// The default remote-debugging setting. Zero means disabled.
    public static let defaultRemoteDebuggingPort: ChromiumRemoteDebuggingPort = .disabled

    // UserDefaults is documented thread-safe. The escape hatch is scoped to
    // this immutable dependency instead of making the whole store unchecked.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a browser settings repository backed by an explicit defaults suite.
    ///
    /// - Parameter defaults: The suite to read and write.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns the engine preference for newly created browser panes.
    ///
    /// - Returns: The persisted engine, failing closed to WebKit.
    public func defaultEngineValue() -> BrowserEngineKind {
        guard let rawValue = defaults.string(forKey: Self.defaultEngineKey),
              !rawValue.isEmpty else {
            return Self.defaultEngine
        }
        return BrowserEngineKind(persistedRawValue: rawValue)
    }

    /// Persists the engine preference for newly created browser panes.
    ///
    /// - Parameter engine: The engine to persist.
    public func setDefaultEngine(_ engine: BrowserEngineKind) {
        defaults.set(engine.rawValue, forKey: Self.defaultEngineKey)
    }

    /// Returns a validated loopback remote-debugging configuration.
    ///
    /// - Returns: The persisted port, or disabled when the stored value is invalid.
    public func remoteDebuggingPort() -> ChromiumRemoteDebuggingPort {
        guard let number = defaults.object(forKey: Self.remoteDebuggingPortKey) as? NSNumber else {
            return Self.defaultRemoteDebuggingPort
        }
        return ChromiumRemoteDebuggingPort(rawValue: number.intValue) ?? Self.defaultRemoteDebuggingPort
    }

    /// Persists a validated loopback remote-debugging configuration.
    ///
    /// - Parameter port: The port value to persist, including zero to disable it.
    public func setRemoteDebuggingPort(_ port: ChromiumRemoteDebuggingPort) {
        defaults.set(port.rawValue, forKey: Self.remoteDebuggingPortKey)
    }
}
