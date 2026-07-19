public import Foundation

/// Persists per-Mac update-hint dismissal signatures in injected user defaults.
public struct MobileMacUpdateHintDismissalStore {
    /// The key prefix for per-Mac dismissal signatures.
    private static let keyPrefix = "cmux.mobile.macUpdateHint.dismissed."

    /// The injected defaults domain used for persistence.
    private let defaults: UserDefaults

    /// Creates a dismissal store backed by the supplied defaults domain.
    ///
    /// - Parameter defaults: The defaults domain to use; production callers default to `UserDefaults.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns whether a Mac dismissed the exact capability-gap signature.
    ///
    /// - Parameters:
    ///   - macDeviceID: The stable identifier of the connected Mac.
    ///   - signature: The current hint's dismissal signature.
    /// - Returns: `true` only when the stored signature exactly matches `signature`.
    public func isDismissed(macDeviceID: String, signature: String) -> Bool {
        defaults.string(forKey: Self.key(for: macDeviceID)) == signature
    }

    /// Persists dismissal of an exact capability gap for one Mac.
    ///
    /// - Parameters:
    ///   - macDeviceID: The stable identifier of the connected Mac.
    ///   - signature: The current hint's dismissal signature.
    public func dismiss(macDeviceID: String, signature: String) {
        defaults.set(signature, forKey: Self.key(for: macDeviceID))
    }

    /// Builds the persistence key for a Mac device identifier.
    ///
    /// - Parameter macDeviceID: The stable identifier of the connected Mac.
    /// - Returns: The defaults key scoped to that Mac.
    private static func key(for macDeviceID: String) -> String {
        keyPrefix + macDeviceID
    }
}
