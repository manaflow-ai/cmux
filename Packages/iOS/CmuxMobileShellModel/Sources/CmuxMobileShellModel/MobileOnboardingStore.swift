public import Foundation

/// Persists the three one-time milestones in the mobile onboarding journey.
///
/// Welcome, Mac connection, and notification priming are tracked independently
/// so the root view can place each experience at the point where it is useful.
/// Flags are read synchronously at construction time, which lets the first frame
/// choose the correct root without flashing an earlier onboarding stage.
///
/// The v1 seen flag is honored as a migration marker. An existing install that
/// saw the old explainer is treated as fully onboarded and never forced through
/// the replacement flow.
///
/// The backing `UserDefaults` is injected so tests can use a suite-scoped store
/// instead of touching `.standard`. `forceSeen` is the UI-test and dogfood bypass:
/// it reports every milestone complete without writing to the user's defaults.
///
/// ```swift
/// let store = MobileOnboardingStore(defaults: .standard)
/// if !store.hasSeenWelcome { /* present the welcome flow */ }
/// store.markWelcomeSeen()
/// ```
public struct MobileOnboardingStore: Sendable {
    /// The defaults key recording completion of the pre-auth welcome pages.
    public static let welcomeSeenKey = "dev.cmux.mobile.onboarding.v2.welcome.seen"
    /// The defaults key recording the first successful Mac connection.
    public static let connectCompletedKey = "dev.cmux.mobile.onboarding.v2.connect.completed"
    /// The defaults key recording that the notification primer was shown.
    public static let notificationsPrimedKey = "dev.cmux.mobile.onboarding.v2.notifications.primed"
    /// The v1 flag retained so existing installs are never re-onboarded.
    public static let legacySeenKey = "dev.cmux.mobile.onboarding.seen.v1"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let forceSeen: Bool

    /// Creates an onboarding store backed by the given defaults.
    ///
    /// - Parameters:
    ///   - defaults: Persistence for onboarding flags. Tests should inject a
    ///     suite-scoped `UserDefaults`.
    ///   - forceSeen: When `true`, every milestone reads as complete and mark
    ///     operations are no-ops, so test and dogfood bypasses never persist.
    public init(defaults: UserDefaults, forceSeen: Bool = false) {
        self.defaults = defaults
        self.forceSeen = forceSeen
    }

    /// Whether the pre-auth welcome pages have already been seen.
    public var hasSeenWelcome: Bool {
        forceSeen || hasSeenLegacyOnboarding || defaults.bool(forKey: Self.welcomeSeenKey)
    }

    /// Whether this install has completed its first Mac connection.
    public var hasCompletedConnect: Bool {
        forceSeen || hasSeenLegacyOnboarding || defaults.bool(forKey: Self.connectCompletedKey)
    }

    /// Whether the one-time notification primer has already been shown.
    public var hasPrimedNotifications: Bool {
        forceSeen || hasSeenLegacyOnboarding || defaults.bool(forKey: Self.notificationsPrimedKey)
    }

    /// Persists completion of the welcome pages unless the store is bypassed.
    public func markWelcomeSeen() {
        guard !forceSeen else { return }
        defaults.set(true, forKey: Self.welcomeSeenKey)
    }

    /// Persists the first successful Mac connection unless the store is bypassed.
    public func markConnectCompleted() {
        guard !forceSeen else { return }
        defaults.set(true, forKey: Self.connectCompletedKey)
    }

    /// Persists that the push primer was shown unless the store is bypassed.
    public func markNotificationsPrimed() {
        guard !forceSeen else { return }
        defaults.set(true, forKey: Self.notificationsPrimedKey)
    }

    /// The v1 explainer's completion marker, promoted to all v2 milestones.
    private var hasSeenLegacyOnboarding: Bool {
        defaults.bool(forKey: Self.legacySeenKey)
    }
}
