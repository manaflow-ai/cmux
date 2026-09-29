public import Foundation
public import Observation

/// Persists signature-based Cloud banner dismissals in user defaults.
@MainActor
@Observable
public final class CloudBannerDismissalStore {
    private static let defaultsKey = "cmux.cloud.banner.dismissed"

    @ObservationIgnored
    private let defaults: UserDefaults
    /// NotificationCenter delivers UserDefaults changes synchronously on the main queue; the token is only touched by this main-actor store and deinit.
    @ObservationIgnored
    private nonisolated(unsafe) var defaultsObserver: (any NSObjectProtocol)?
    /// The signatures currently hidden by this store's banner surfaces.
    public private(set) var dismissedSignatures: [String: String]

    /// Creates a dismissal repository backed by the supplied defaults store.
    ///
    /// - Parameter defaults: The defaults store used for persistence. Pass a
    ///   suite-scoped store in tests to isolate state from the user account.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        dismissedSignatures = Self.load(from: defaults)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadFromDefaults()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Returns whether the current signature was dismissed for the identifier.
    ///
    /// - Parameters:
    ///   - id: Stable identifier for the banner instance.
    ///   - signature: State-and-copy signature for the current banner.
    /// - Returns: `true` only when the stored signature exactly matches.
    public func isDismissed(id: String, signature: String) -> Bool {
        Self.load(from: defaults)[id] == signature
    }

    /// Records a dismissal without overwriting newer entries from another client.
    ///
    /// - Parameters:
    ///   - id: Stable identifier for the banner instance.
    ///   - signature: State-and-copy signature to suppress.
    public func dismiss(id: String, signature: String) {
        var next = Self.load(from: defaults)
        next[id] = signature
        dismissedSignatures = next
        persist()
    }

    /// Removes the dismissal for one banner identifier.
    ///
    /// - Parameter id: Stable identifier whose dismissal should be cleared.
    public func clear(id: String) {
        var next = Self.load(from: defaults)
        next.removeValue(forKey: id)
        dismissedSignatures = next
        persist()
    }

    private static func load(from defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    private func reloadFromDefaults() {
        dismissedSignatures = Self.load(from: defaults)
    }

    private func persist() {
        defaults.set(dismissedSignatures, forKey: Self.defaultsKey)
    }
}
