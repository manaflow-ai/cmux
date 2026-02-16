import AppKit
import Foundation
import PostHog

@MainActor
final class PostHogAnalytics {
    static let shared = PostHogAnalytics()

    // The PostHog project API key is intentionally embedded in the app (it's a public key).
    private let apiKey = "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP"

    // PostHog Cloud US default (matches other cmux properties).
    private let host = "https://us.i.posthog.com"

    private let lastActiveDayUTCKey = "posthog.lastActiveDayUTC"

    private var didStart = false
    private var activeCheckTimer: Timer?

    private var isEnabled: Bool {
#if DEBUG
        // Avoid polluting production analytics while iterating locally.
        return ProcessInfo.processInfo.environment["CMUX_POSTHOG_ENABLE"] == "1"
#else
        return !apiKey.isEmpty && apiKey != "REPLACE_WITH_POSTHOG_PUBLIC_KEY"
#endif
    }

    func startIfNeeded() {
        guard !didStart else { return }
        guard isEnabled else { return }

        let config = PostHogConfig(apiKey: apiKey, host: host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
#if DEBUG
        config.debug = ProcessInfo.processInfo.environment["CMUX_POSTHOG_DEBUG"] == "1"
#endif

        PostHogSDK.shared.setup(config)

        // Tag every event so PostHog can distinguish desktop from web.
        PostHogSDK.shared.register(["platform": "cmuxterm"])

        // The SDK automatically generates and persists an anonymous distinct ID.

        didStart = true

        // If the app stays in the foreground across midnight, `applicationDidBecomeActive`
        // won't fire again, so a periodic check avoids undercounting those users.
        activeCheckTimer?.invalidate()
        activeCheckTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard NSApp.isActive else { return }
            self.trackDailyActive(reason: "activeTimer")
        }
    }

    func trackDailyActive(reason: String) {
        startIfNeeded()
        guard didStart else { return }

        let today = utcDayString(Date())
        let defaults = UserDefaults.standard
        if defaults.string(forKey: lastActiveDayUTCKey) == today {
            return
        }

        defaults.set(today, forKey: lastActiveDayUTCKey)

        PostHogSDK.shared.capture("cmux_daily_active", properties: [
            "day_utc": today,
            "reason": reason,
        ])

        // For DAU we care more about delivery than batching.
        PostHogSDK.shared.flush()
    }

    func flush() {
        guard didStart else { return }
        PostHogSDK.shared.flush()
    }

    private func utcDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
