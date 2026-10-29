import CmuxCloud
import CmuxProductAnalytics
import CmuxSettings
import Foundation

extension ProductAnalytics {
    /// The app's product analytics, sending through ``PostHogAnalytics``.
    /// Disabled whenever PostHog capture is (telemetry opt-out in Settings,
    /// managed `DisableTelemetry`, XCTest, debug builds without
    /// `CMUX_POSTHOG_ENABLE=1`), so it enqueues nothing in those launches.
    static let app: ProductAnalytics = {
        let posthog = PostHogAnalytics.shared
        let defaults = UserDefaults.standard
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ProductAnalytics(
            isEnabled: posthog.isCaptureEnabled,
            sink: PostHogProductAnalyticsSink(analytics: posthog),
            ledger: ProductAnalyticsLedger(defaults: defaults),
            context: ProductAnalyticsContext(
                appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                appBuild: info["CFBundleVersion"] as? String ?? "unknown",
                channel: BuildFlavor.current.rawValue,
                osVersion: "\(os.majorVersion).\(os.minorVersion)",
                cloudEnabled: CloudMachinesFeature.offMainIsEnabled()
            ),
            isPreexistingInstall: isPreexistingInstall(defaults: defaults)
        )
    }()

    /// An install that ran before the event catalog shipped leaves earlier
    /// analytics or campaign markers; its first launch is not reported now.
    static func isPreexistingInstall(defaults: UserDefaults) -> Bool {
        defaults.string(forKey: "posthog.lastActiveDayUTC") != nil
            || defaults.string(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) != nil
    }
}
