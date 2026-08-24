public import Foundation

/// `UserDefaults` installation marker storage for production composition.
public final class CmxIrohUserDefaultsInstallStateStore: CmxIrohInstallStateStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    /// Creates a state store.
    ///
    /// - Parameter defaults: The app-local defaults domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
