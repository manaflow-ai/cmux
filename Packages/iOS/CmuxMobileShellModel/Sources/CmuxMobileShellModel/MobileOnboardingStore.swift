public import Foundation

/// Tracks whether the user has seen the first-run onboarding, persisted in an
/// injected `UserDefaults`.
///
/// The onboarding explains what cmux is and how the phone pairs to a Mac. It is
/// presented post-authentication, in front of the never-paired add-device state,
/// and must show once per install and never reappear. The seen flag is read
/// synchronously at construction time (mirroring `MobileClientIDRepository` /
/// `MobileDisplaySettings`): the root view reads it before deciding what to
/// mount, which avoids a flash of the add-device screen ahead of onboarding on
/// first launch.
///
/// The backing `UserDefaults` is injected so the store is testable without
/// touching `.standard`; the app constructs it at the composition root with
/// `UserDefaults.standard`.
///
/// `forceSeen` lets the caller treat onboarding as already seen regardless of
/// what is persisted. The mobile app passes the UI-test / dogfood bypass through
/// this so the XCUITest harness and the dev-launch auto-pair path are not wedged
/// behind a manual tap-through (the bypass decision itself lives in the UI layer,
/// which can read `UITestConfig`; this type stays dependency-light).
///
/// ```swift
/// let store = MobileOnboardingStore(defaults: .standard, forceSeen: false)
/// if !store.hasSeenOnboarding { /* present onboarding */ }
/// store.markSeen()
/// ```
public struct MobileOnboardingStore: Sendable {
    /// The defaults key under which the seen flag is stored.
    public static let defaultsKey = "dev.cmux.mobile.onboarding.seen.v1"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let forceSeen: Bool

    /// Create a store backed by the given defaults.
    /// - Parameters:
    ///   - defaults: The persistence store for the seen flag. Inject a
    ///     suite-scoped `UserDefaults` in tests.
    ///   - forceSeen: When `true`, ``hasSeenOnboarding`` always returns `true`
    ///     and ``markSeen()`` is a no-op, so onboarding never presents. The app
    ///     passes the UI-test / dogfood bypass here.
    public init(defaults: UserDefaults, forceSeen: Bool = false) {
        self.defaults = defaults
        self.forceSeen = forceSeen
    }

    /// Whether the first-run onboarding has already been shown on this install.
    ///
    /// Returns `true` when `forceSeen` is set (UI-test / dogfood bypass) or when
    /// the seen flag is persisted. Read synchronously so the root view never
    /// flashes a later screen before deciding to present onboarding.
    public var hasSeenOnboarding: Bool {
        if forceSeen { return true }
        return defaults.bool(forKey: Self.defaultsKey)
    }

    /// Persist that the user has finished (or skipped) onboarding.
    ///
    /// A no-op when `forceSeen` is set, so the bypass never writes through to the
    /// real install's defaults.
    public func markSeen() {
        guard !forceSeen else { return }
        defaults.set(true, forKey: Self.defaultsKey)
    }
}
