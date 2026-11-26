internal import CMUXMobileCore
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

    /// Returns whether a Mac pairing dismissed the exact capability-gap signature.
    ///
    /// - Parameters:
    ///   - macDeviceID: The stable identifier of the connected Mac.
    ///   - instanceTag: The connected app instance, or `nil` for a legacy
    ///     untagged pairing. Sibling builds of one Mac dismiss independently.
    ///   - signature: The current hint's dismissal signature.
    /// - Returns: `true` only when the stored signature exactly matches `signature`.
    public func isDismissed(macDeviceID: String, instanceTag: String?, signature: String) -> Bool {
        defaults.string(forKey: Self.key(for: macDeviceID, instanceTag: instanceTag)) == signature
    }

    /// Persists dismissal of an exact capability gap for one Mac pairing.
    ///
    /// - Parameters:
    ///   - macDeviceID: The stable identifier of the connected Mac.
    ///   - instanceTag: The connected app instance, or `nil` for a legacy
    ///     untagged pairing.
    ///   - signature: The current hint's dismissal signature.
    public func dismiss(macDeviceID: String, instanceTag: String?, signature: String) {
        defaults.set(signature, forKey: Self.key(for: macDeviceID, instanceTag: instanceTag))
    }

    /// Builds the persistence key for one Mac pairing. Tagged pairings get a
    /// per-build key; untagged pairings keep the legacy device-level key.
    private static func key(for macDeviceID: String, instanceTag: String?) -> String {
        keyPrefix + CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).id
    }
}
