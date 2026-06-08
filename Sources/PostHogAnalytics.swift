import AppKit
import Foundation
import PostHog

final class PostHogAnalytics {
    static let shared = PostHogAnalytics()

    // The PostHog project API key is intentionally embedded in the app (it's a public key).
    private let apiKey = "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP"

    // PostHog Cloud US default (matches other cmux properties).
    private let host = "https://us.i.posthog.com"

    private let dailyActiveEvent = "cmux_daily_active"
    private let hourlyActiveEvent = "cmux_hourly_active"

    private let lastActiveDayUTCKey = "posthog.lastActiveDayUTC"
    private let lastActiveHourUTCKey = "posthog.lastActiveHourUTC"

    private let workQueue: DispatchQueue
    private let workQueueSpecificKey = DispatchSpecificKey<Void>()
    private let utcHourFormatter: DateFormatter
    private let utcDayFormatter: DateFormatter

    private var didStart = false
    private var activeCheckTimer: Timer?

    private init() {
        workQueue = DispatchQueue(label: "com.cmux.posthog.analytics", qos: .utility)
        utcHourFormatter = Self.makeUTCFormatter("yyyy-MM-dd'T'HH")
        utcDayFormatter = Self.makeUTCFormatter("yyyy-MM-dd")
        workQueue.setSpecific(key: workQueueSpecificKey, value: ())
    }

    private var isEnabled: Bool {
        guard TelemetrySettings.enabledForCurrentLaunch else { return false }
#if DEBUG
        // Avoid polluting production analytics while iterating locally.
        return ProcessInfo.processInfo.environment["CMUX_POSTHOG_ENABLE"] == "1"
#else
        return !apiKey.isEmpty && apiKey != "REPLACE_WITH_POSTHOG_PUBLIC_KEY"
#endif
    }

    func startIfNeeded() {
        dispatchAsyncOnWorkQueue { [weak self] in
            self?.startIfNeededOnWorkQueue()
        }
    }

    func trackActive(reason: String) {
        dispatchAsyncOnWorkQueue { [weak self] in
            guard let self else { return }

            let didCaptureDaily = self.trackDailyActiveOnWorkQueue(reason: reason, flush: false)
            let didCaptureHourly = self.trackHourlyActiveOnWorkQueue(reason: reason, flush: false)
            if didCaptureDaily || didCaptureHourly {
                // On app focus we can capture both events; flush once to reduce extra work.
                PostHogSDK.shared.flush()
            }
        }
    }

    func trackDailyActive(reason: String) {
        dispatchAsyncOnWorkQueue { [weak self] in
            self?.trackDailyActiveOnWorkQueue(reason: reason, flush: true)
        }
    }

    func trackHourlyActive(reason: String) {
        dispatchAsyncOnWorkQueue { [weak self] in
            self?.trackHourlyActiveOnWorkQueue(reason: reason, flush: true)
        }
    }

    func flush() {
        dispatchSyncOnWorkQueue {
            guard didStart else { return }
            PostHogSDK.shared.flush()
        }
    }

    /// Associates subsequent events with the signed-in Stack user id so the
    /// desktop app keys on the same distinct id as the iOS proxy (which stamps
    /// the authenticated Stack `user.id`). PostHog back-merges the pre-login
    /// anonymous events into the identified user, so the desktop install's
    /// pre-sign-in funnel attaches to the same person across iOS and macOS.
    ///
    /// - Parameter stackUserID: The signed-in Stack user id. Empty values are
    ///   ignored so a partially-resolved identity can't identify as "".
    func identify(stackUserID: String) {
        let trimmed = stackUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dispatchAsyncOnWorkQueue { [weak self] in
            guard let self else { return }
            self.startIfNeededOnWorkQueue()
            guard self.didStart else { return }
            // Identify must run after `setup()` or the SDK drops it; the
            // `startIfNeededOnWorkQueue()` guard above mirrors the active-event path.
            PostHogSDK.shared.identify(trimmed)
        }
    }

    /// Resets analytics identity back to a fresh anonymous distinct id when
    /// PostHog currently holds an *identified* (signed-in) distinct id, so a
    /// subsequent different sign-in does not merge into the prior user. Mirrors
    /// the iOS `identify(userId: nil)` reset.
    ///
    /// The SDK's own persisted distinct id is the single source of truth (no
    /// parallel flag): the reset fires only when the current distinct id differs
    /// from the anonymous id (`reset()` regenerates the anonymous id, so calling
    /// it on an already-anonymous user would fragment a perpetually-signed-out
    /// user's retention into a new id per launch). Starts the SDK first (like
    /// ``identify(stackUserID:)``) so the persisted distinct id from a prior
    /// identified session is reset *before* the first active/retention event
    /// starts it with the stale id. When telemetry is disabled
    /// `startIfNeededOnWorkQueue()` leaves `didStart` false, so this is a no-op
    /// (and no analytics are emitted at all); the SDK's persisted identity is
    /// untouched, so a later launch with telemetry on still resets it on the
    /// same signed-out edge.
    func reset() {
        dispatchAsyncOnWorkQueue { [weak self] in
            guard let self else { return }
            self.startIfNeededOnWorkQueue()
            guard self.didStart else { return }
            guard Self.shouldResetIdentity(
                distinctID: PostHogSDK.shared.getDistinctId(),
                anonymousID: PostHogSDK.shared.getAnonymousId()
            ) else { return }
            PostHogSDK.shared.reset()
        }
    }

    /// Whether a `reset()` is needed: true only when PostHog currently holds an
    /// identified distinct id (one that differs from the anonymous id). Pure and
    /// `nonisolated` so the signed-out / perpetually-anonymous / re-login
    /// invariants are unit-testable without the SDK.
    nonisolated static func shouldResetIdentity(distinctID: String, anonymousID: String) -> Bool {
        !distinctID.isEmpty && distinctID != anonymousID
    }

    private func startIfNeededOnWorkQueue() {
        guard !didStart else { return }
        guard isEnabled else { return }

        let config = PostHogConfig(apiKey: apiKey, host: host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
#if DEBUG
        config.debug = ProcessInfo.processInfo.environment["CMUX_POSTHOG_DEBUG"] == "1"
#endif

        PostHogSDK.shared.setup(config)

        // Tag every event so PostHog can distinguish desktop from web and
        // break events down by released app version/build.
        PostHogSDK.shared.register(Self.superProperties(infoDictionary: Bundle.main.infoDictionary ?? [:]))

        // The SDK automatically generates and persists an anonymous distinct ID.

        didStart = true

        scheduleActiveCheckTimer()
    }

    private func scheduleActiveCheckTimer() {
        // If the app stays in the foreground across midnight, `applicationDidBecomeActive`
        // won't fire again, so a periodic check avoids undercounting those users.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeCheckTimer?.invalidate()
            self.activeCheckTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard NSApp.isActive else { return }
                self.trackActive(reason: "activeTimer")
            }
        }
    }

    @discardableResult
    private func trackDailyActiveOnWorkQueue(reason: String, flush: Bool) -> Bool {
        startIfNeededOnWorkQueue()
        guard didStart else { return false }

        let today = utcDayString(Date())
        let defaults = UserDefaults.standard
        if defaults.string(forKey: lastActiveDayUTCKey) == today {
            return false
        }

        defaults.set(today, forKey: lastActiveDayUTCKey)

        let event = dailyActiveEvent

        PostHogSDK.shared.capture(
            event,
            properties: Self.dailyActiveProperties(
                dayUTC: today,
                reason: reason,
                infoDictionary: Bundle.main.infoDictionary ?? [:]
            )
        )

        if flush && Self.shouldFlushAfterCapture(event: event) {
            // For active metrics we care more about delivery than batching.
            PostHogSDK.shared.flush()
        }

        return true
    }

    @discardableResult
    private func trackHourlyActiveOnWorkQueue(reason: String, flush: Bool) -> Bool {
        startIfNeededOnWorkQueue()
        guard didStart else { return false }

        let hour = utcHourString(Date())
        let defaults = UserDefaults.standard
        if defaults.string(forKey: lastActiveHourUTCKey) == hour {
            return false
        }

        defaults.set(hour, forKey: lastActiveHourUTCKey)

        let event = hourlyActiveEvent

        PostHogSDK.shared.capture(
            event,
            properties: Self.hourlyActiveProperties(
                hourUTC: hour,
                reason: reason,
                infoDictionary: Bundle.main.infoDictionary ?? [:]
            )
        )

        if flush && Self.shouldFlushAfterCapture(event: event) {
            // Keep hourly freshness and avoid losing a deduped hour on abrupt exits.
            PostHogSDK.shared.flush()
        }

        return true
    }

    private func dispatchAsyncOnWorkQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: workQueueSpecificKey) != nil {
            block()
            return
        }
        workQueue.async(execute: block)
    }

    private func dispatchSyncOnWorkQueue(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: workQueueSpecificKey) != nil {
            block()
            return
        }
        workQueue.sync(execute: block)
    }

    private func utcHourString(_ date: Date) -> String {
        utcHourFormatter.string(from: date)
    }

    private func utcDayString(_ date: Date) -> String {
        utcDayFormatter.string(from: date)
    }

    private static func makeUTCFormatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = dateFormat
        return formatter
    }

    nonisolated static func superProperties(infoDictionary: [String: Any]) -> [String: Any] {
        var properties: [String: Any] = ["platform": "cmuxterm"]
        properties.merge(versionProperties(infoDictionary: infoDictionary)) { _, new in new }
        return properties
    }

    nonisolated static func dailyActiveProperties(
        dayUTC: String,
        reason: String,
        infoDictionary: [String: Any]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "day_utc": dayUTC,
            "reason": reason,
        ]
        properties.merge(versionProperties(infoDictionary: infoDictionary)) { _, new in new }
        return properties
    }

    nonisolated static func hourlyActiveProperties(
        hourUTC: String,
        reason: String,
        infoDictionary: [String: Any]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "hour_utc": hourUTC,
            "reason": reason,
        ]
        properties.merge(versionProperties(infoDictionary: infoDictionary)) { _, new in new }
        return properties
    }

    nonisolated static func shouldFlushAfterCapture(event: String) -> Bool {
        switch event {
        case "cmux_daily_active", "cmux_hourly_active":
            return true
        default:
            return false
        }
    }

    nonisolated private static func versionProperties(infoDictionary: [String: Any]) -> [String: Any] {
        var properties: [String: Any] = [:]
        if let value = infoDictionary["CFBundleShortVersionString"] as? String, !value.isEmpty {
            properties["app_version"] = value
        }
        if let value = infoDictionary["CFBundleVersion"] as? String, !value.isEmpty {
            properties["app_build"] = value
        }
        return properties
    }
}
