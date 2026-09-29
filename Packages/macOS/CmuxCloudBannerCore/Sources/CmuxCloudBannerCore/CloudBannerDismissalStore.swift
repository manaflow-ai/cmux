public import Foundation
public import Combine

/// Persists signature-based Cloud banner dismissals in user defaults.
@MainActor
public final class CloudBannerDismissalStore: ObservableObject {
    private static let defaultsKey = "cmux.cloud.banner.dismissed"

    private let defaults: UserDefaults
    @Published public private(set) var dismissedSignatures: [String: String]
    private nonisolated(unsafe) var defaultsObserver: (any NSObjectProtocol)?

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
    /// The persisted map is reloaded before every read so a long-lived client
    /// observes dismissals written by another live client.
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
