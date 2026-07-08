import AppKit

/// Presents the one-time "Welcome to cmux Pro" checklist after a user becomes
/// Pro. The checklist is a chromeless in-app web page (`/app-pro-welcome`)
/// shown in the same dedicated workspace surface as the pricing page, so it
/// matches how upgrade/pricing already appears. Automatic presentation is
/// gated on Pro status, a persisted seen-flag, and the Pro upgrade UI feature
/// flag; manual and debug entrypoints call `present()` directly.
enum ProWelcomeChecklistPresenter {
    static let seenDefaultsKey = "cmux.pro.welcomeChecklist.seen"

    static func shouldPresentAutomatically(isPro: Bool, seen: Bool, flagEnabled: Bool) -> Bool {
        isPro && !seen && flagEnabled
    }

    /// Whether the automatic checklist could plausibly be shown, ignoring the
    /// Pro status that only a network fetch can determine. Lets callers skip
    /// the `/api/billing/plan` fetch entirely when the checklist is already
    /// seen or the Pro upgrade UI flag is off (the common Release path).
    static func canPresentAutomatically(
        flagEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        flagEnabled && !defaults.bool(forKey: seenDefaultsKey)
    }

    static func consumeAutomaticPresentation(
        isPro: Bool,
        flagEnabled: Bool,
        defaults: UserDefaults
    ) -> Bool {
        let seen = defaults.bool(forKey: seenDefaultsKey)
        guard shouldPresentAutomatically(isPro: isPro, seen: seen, flagEnabled: flagEnabled) else {
            return false
        }
        defaults.set(true, forKey: seenDefaultsKey)
        return true
    }

    @MainActor
    static func present() {
        ProUpgradePresenter.presentProWelcomeWeb()
    }

    @MainActor
    static func presentIfNewlyPro(isPro: Bool, defaults: UserDefaults = .standard) {
        guard consumeAutomaticPresentation(
            isPro: isPro,
            flagEnabled: CmuxFeatureFlags.shared.isProUpgradeUIEnabled,
            defaults: defaults
        ) else {
            return
        }
        present()
    }
}
