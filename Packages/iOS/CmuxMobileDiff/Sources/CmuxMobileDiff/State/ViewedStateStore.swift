internal import Foundation

/// Persists content-sensitive viewed decisions in injected device-local defaults.
struct ViewedStateStore: Sendable {
    /// Defaults key containing encoded viewed identities.
    static let defaultsKey = "dev.cmux.mobile.diff.viewed.v1"

    // UserDefaults is Apple-documented thread-safe; the mutable value snapshot is held separately.
    private nonisolated(unsafe) let defaults: UserDefaults
    private var viewed: Set<String>

    /// Creates a viewed-state store.
    /// - Parameter defaults: Injected defaults; tests should use a suite-scoped instance.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        viewed = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Returns whether a content-sensitive key is viewed.
    /// - Parameter key: Workspace, path, and digest identity.
    func isViewed(_ key: ViewedFileKey) -> Bool {
        viewed.contains(key.rawValue)
    }

    /// Updates and immediately persists viewed state.
    /// - Parameters:
    ///   - viewed: New viewed decision.
    ///   - key: Workspace, path, and digest identity.
    mutating func setViewed(_ viewed: Bool, for key: ViewedFileKey) {
        if viewed {
            self.viewed.insert(key.rawValue)
        } else {
            self.viewed.remove(key.rawValue)
        }
        defaults.set(self.viewed.sorted(), forKey: Self.defaultsKey)
    }
}
