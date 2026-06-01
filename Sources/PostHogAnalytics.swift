import AppKit
import Foundation
import OSLog
import PostHog

nonisolated private let postHogAnalyticsLogger = Logger(subsystem: "com.cmuxterm.app", category: "PostHogAnalytics")
nonisolated private let postHogAnalyticsSignposter = OSSignposter(logger: postHogAnalyticsLogger)

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
    private let terminationFlushQueue: DispatchQueue
    private let workQueueSpecificKey = DispatchSpecificKey<Void>()
    private let utcHourFormatter: DateFormatter
    private let utcDayFormatter: DateFormatter
    private let sdkFlush: () -> Void

    private var didStart = false
    private var activeCheckTimer: Timer?

    // Internal so @testable regression tests can inject a busy queue and stub flush.
    internal init(
        workQueue: DispatchQueue = DispatchQueue(label: "com.cmux.posthog.analytics", qos: .utility),
        terminationFlushQueue: DispatchQueue = DispatchQueue(label: "com.cmux.posthog.analytics.terminationFlush", qos: .utility),
        didStart: Bool = false,
        sdkFlush: @escaping () -> Void = { PostHogSDK.shared.flush() }
    ) {
        self.workQueue = workQueue
        self.terminationFlushQueue = terminationFlushQueue
        self.sdkFlush = sdkFlush
        self.didStart = didStart
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
                self.flushOnWorkQueue(reason: "trackActive")
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
        flushSynchronously(reason: "manual")
    }

    func flushForApplicationTermination(
        reason: String = "applicationWillTerminate",
        preservePendingCaptures: Bool = false
    ) {
        if preservePendingCaptures {
            enqueueFlush(reason: reason)
        } else {
            enqueueTerminationFlush(reason: reason)
        }
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
            flushOnWorkQueue(reason: "trackDailyActive")
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
            flushOnWorkQueue(reason: "trackHourlyActive")
        }

        return true
    }

    private func flushSynchronously(reason: String) {
        postHogAnalyticsLogger.debug("posthog.flush.sync.request reason=\(reason, privacy: .public)")
#if DEBUG
        cmuxDebugLog("posthog.flush.sync.request reason=\(reason)")
#endif
        dispatchSyncOnWorkQueue { [self] in
            flushOnWorkQueue(reason: reason)
        }
    }

    private func enqueueFlush(reason: String) {
        postHogAnalyticsLogger.debug("posthog.flush.enqueue reason=\(reason, privacy: .public)")
#if DEBUG
        cmuxDebugLog("posthog.flush.enqueue reason=\(reason)")
#endif

        if DispatchQueue.getSpecific(key: workQueueSpecificKey) != nil {
            flushOnWorkQueue(reason: reason)
            return
        }

        let workItem = DispatchWorkItem { [self] in
            flushOnWorkQueue(reason: reason)
        }
        workQueue.async(execute: workItem)
    }

    private func enqueueTerminationFlush(reason: String) {
        postHogAnalyticsLogger.debug("posthog.flush.termination.enqueue reason=\(reason, privacy: .public)")
#if DEBUG
        cmuxDebugLog("posthog.flush.termination.enqueue reason=\(reason)")
#endif

        let workItem = DispatchWorkItem { [sdkFlush] in
            Self.performSDKFlush(reason: reason, sdkFlush: sdkFlush)
        }
        terminationFlushQueue.async(execute: workItem)
    }

    private func flushOnWorkQueue(reason: String) {
        guard didStart else {
            postHogAnalyticsLogger.debug("posthog.flush.skip reason=\(reason, privacy: .public) started=0")
#if DEBUG
            cmuxDebugLog("posthog.flush.skip reason=\(reason) started=0")
#endif
            return
        }

        Self.performSDKFlush(reason: reason, sdkFlush: sdkFlush)
    }

    private nonisolated static func performSDKFlush(reason: String, sdkFlush: () -> Void) {
        let signpostID = postHogAnalyticsSignposter.makeSignpostID()
        let signpostState = postHogAnalyticsSignposter.beginInterval(
            "PostHog Flush",
            id: signpostID,
            "reason=\(reason, privacy: .public)"
        )
        let start = DispatchTime.now().uptimeNanoseconds
        postHogAnalyticsLogger.debug("posthog.flush.begin reason=\(reason, privacy: .public)")
#if DEBUG
        cmuxDebugLog("posthog.flush.begin reason=\(reason)")
#endif
        sdkFlush()
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        postHogAnalyticsLogger.info("posthog.flush.end reason=\(reason, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
#if DEBUG
        cmuxDebugLog("posthog.flush.end reason=\(reason) elapsedMs=\(String(format: "%.1f", elapsedMilliseconds))")
#endif
        postHogAnalyticsSignposter.endInterval("PostHog Flush", signpostState)
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
