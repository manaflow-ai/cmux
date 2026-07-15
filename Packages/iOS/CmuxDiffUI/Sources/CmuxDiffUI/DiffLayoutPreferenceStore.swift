public import Foundation

/// Persists the user's manual unified/split override for diff screens.
public struct DiffLayoutPreferenceStore: Sendable {
    /// The defaults entry containing the selected layout override.
    public static let defaultsKey = "dev.cmux.mobile.diff.layoutOverride.v1"

    // UserDefaults is Apple-documented thread-safe; the dependency is injected.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a layout preference store over an injected defaults suite.
    /// - Parameter defaults: The persistence suite; tests should inject an isolated suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Reads the persisted override, defaulting to orientation-driven layout.
    /// - Returns: The stored override or ``DiffLayoutOverride/automatic``.
    public func load() -> DiffLayoutOverride {
        defaults.string(forKey: Self.defaultsKey)
            .flatMap(DiffLayoutOverride.init(rawValue:)) ?? .automatic
    }

    /// Persists a layout override.
    /// - Parameter override: The override to save.
    public func save(_ override: DiffLayoutOverride) {
        defaults.set(override.rawValue, forKey: Self.defaultsKey)
    }
}
