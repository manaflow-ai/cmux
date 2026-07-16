public import Foundation

/// Persists whether the notification-feed education card has been dismissed.
public struct MobileNotificationFeedIntroStore: Sendable {
    /// The defaults key storing the dismissal flag.
    public static let defaultsKey = "dev.cmux.mobile.notification-feed.intro.dismissed.v1"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let forceDismissed: Bool

    /// Creates an intro-card persistence store.
    /// - Parameters:
    ///   - defaults: The injected persistence store.
    ///   - forceDismissed: Whether to suppress the card without writing defaults.
    public init(defaults: UserDefaults, forceDismissed: Bool = false) {
        self.defaults = defaults
        self.forceDismissed = forceDismissed
    }

    /// Whether the education card should no longer be shown.
    public var hasDismissedIntro: Bool {
        forceDismissed || defaults.bool(forKey: Self.defaultsKey)
    }

    /// Persists that the education card was dismissed.
    public func markDismissed() {
        guard !forceDismissed else { return }
        defaults.set(true, forKey: Self.defaultsKey)
    }
}
