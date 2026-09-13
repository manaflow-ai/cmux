public import Foundation

/// Persists signature-based Cloud banner dismissals in user defaults.
@MainActor
public final class CloudBannerDismissalStore {
    private static let defaultsKey = "cmux.cloud.banner.dismissed"

    private let defaults: UserDefaults
    private var dismissedSignatures: [String: String]

    /// Creates a dismissal repository backed by the supplied defaults store.
    ///
    /// - Parameter defaults: The defaults store used for persistence. Pass a
    ///   suite-scoped store in tests to isolate state from the user account.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        dismissedSignatures = Self.load(from: defaults)
    }

    /// Returns whether the current signature was dismissed for the identifier.
    ///
    /// The persisted map is reloaded before every read so a long-lived client
    /// observes dismissals written by another live client.
    ///
    /// - Parameters:
    ///   - id: Stable identifier for the banner instance.
    ///   - signature: State-and-copy signature for the current banner.
    /// - Returns: `true` only when the stored signature exactly matches.
    public func isDismissed(id: String, signature: String) -> Bool {
        dismissedSignatures = Self.load(from: defaults)
        return dismissedSignatures[id] == signature
    }

    /// Records a dismissal without overwriting newer entries from another client.
    ///
    /// - Parameters:
    ///   - id: Stable identifier for the banner instance.
    ///   - signature: State-and-copy signature to suppress.
    public func dismiss(id: String, signature: String) {
        dismissedSignatures = Self.load(from: defaults)
        dismissedSignatures[id] = signature
        persist()
    }

    /// Removes the dismissal for one banner identifier.
    ///
    /// - Parameter id: Stable identifier whose dismissal should be cleared.
    public func clear(id: String) {
        dismissedSignatures = Self.load(from: defaults)
        dismissedSignatures.removeValue(forKey: id)
        persist()
    }

    private static func load(from defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    private func persist() {
        defaults.set(dismissedSignatures, forKey: Self.defaultsKey)
    }
}
