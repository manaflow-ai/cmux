import Foundation
import Observation
import PostHog

/// PostHog-backed runtime feature flags for the macOS app (PostHog project
/// 244066, same public key analytics uses). Values are cached in memory and
/// refreshed when the SDK reports a flag payload, so gated UI can be toggled
/// from the PostHog dashboard without shipping a build.
///
/// Fallback semantics (flags must never break the app):
/// - Until a payload arrives — including forever, when the SDK never starts
///   because telemetry is off or a DEBUG build lacks CMUX_POSTHOG_ENABLE=1 —
///   every flag keeps its safe default.
/// - Once a payload has arrived, an absent or false flag reads as off, so
///   the dashboard toggle is an effective kill switch.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class CmuxFeatureFlags {
    static let shared = CmuxFeatureFlags()

    // FLAG(key: pro-upgrade-ui-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
    // Shows the Pro upgrade entrypoints (sidebar badge, Settings Account
    // card, palette command, Help menu item). The default keeps them visible
    // when flags are unavailable: they only open the public pricing page.
    private(set) var isProUpgradeUIEnabled = true

    private static let proUpgradeUIKey = "pro-upgrade-ui-enabled-release"

    // FLAG(key: mobile-connect-button-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
    // Shows the top-right iPhone button that opens the Mobile Connect
    // (phone pairing) window. Default keeps it visible when flags are
    // unavailable; the window it opens ships in every build.
    private(set) var isMobileConnectButtonEnabled = true

    private static let mobileConnectButtonKey = "mobile-connect-button-enabled-release"

    private var flagsObserver: (any NSObjectProtocol)?

    /// Called once from AppDelegate after PostHog analytics starts. Safe when
    /// the SDK never sets up — flags then keep their defaults.
    func start() {
        guard flagsObserver == nil else { return }
        flagsObserver = NotificationCenter.default.addObserver(
            forName: PostHogSDK.didReceiveFeatureFlags,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyLoadedFlags()
            }
        }
        PostHogSDK.shared.reloadFeatureFlags()
    }

    private func applyLoadedFlags() {
        isProUpgradeUIEnabled =
            PostHogSDK.shared.getFeatureFlag(Self.proUpgradeUIKey) as? Bool ?? false
        isMobileConnectButtonEnabled =
            PostHogSDK.shared.getFeatureFlag(Self.mobileConnectButtonKey) as? Bool ?? false
    }
}
