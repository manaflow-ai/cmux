import AppKit
import CmuxSettings
import Foundation
import PostHog

// `@unchecked Sendable` is safe here because mutable analytics state is confined
// to `workQueue`; `activeCheckTimer` is only touched through the main queue.
final class PostHogAnalytics: @unchecked Sendable {
    static let shared = PostHogAnalytics()

    // The PostHog project API key is intentionally embedded in the app (it's a public key).
    private let apiKey = "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP"

    // PostHog Cloud US default (matches other cmux properties).
    private let host = "https://us.i.posthog.com"

    private let dailyActiveEvent = "cmux_daily_active"
    private let hourlyActiveEvent = "cmux_hourly_active"
    private let crashExceptionEvent = "$exception"

    private let lastActiveDayUTCKey = "posthog.lastActiveDayUTC"
    private let lastActiveHourUTCKey = "posthog.lastActiveHourUTC"
    private let lastReportedCrashAtKey = "posthog.lastReportedCrashAt"

    private let workQueue: DispatchQueue
    private let workQueueSpecificKey = DispatchSpecificKey<Void>()
    private let utcHourFormatter: DateFormatter
    private let utcDayFormatter: DateFormatter
    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private let capturePostHog: @Sendable (String, [String: Any]) -> Void
    private let flushPostHog: @Sendable () -> Void
    private let environment: [String: String]
    private let telemetryEnabled: @Sendable () -> Bool
    /// The `updates.channel` selection, read per event so RC-channel installs stay distinguishable.
    private let updateChannel: @Sendable () -> UpdateChannel
    private let previousLaunchIdentity: [String: Any]
    private let launchStartedAt: Date

    private var didStart: Bool
    private var activeCheckTimer: Timer?

    init(
        workQueue: DispatchQueue = DispatchQueue(label: "com.cmux.posthog.analytics", qos: .utility),
        didStart: Bool = false,
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        capturePostHog: @escaping @Sendable (String, [String: Any]) -> Void = { event, properties in
            PostHogSDK.shared.capture(event, properties: properties)
        },
        flushPostHog: @escaping @Sendable () -> Void = { PostHogSDK.shared.flush() },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        telemetryEnabled: @escaping @Sendable () -> Bool = { TelemetrySettings.enabledForCurrentLaunch },
        updateChannel: @escaping @Sendable () -> UpdateChannel = PostHogAnalytics.configFileUpdateChannelReader()
    ) {
        self.workQueue = workQueue
        self.didStart = didStart
        self.userDefaults = userDefaults
        self.now = now
        self.capturePostHog = capturePostHog
        self.flushPostHog = flushPostHog
        self.environment = environment
        self.telemetryEnabled = telemetryEnabled
        self.updateChannel = updateChannel
        self.previousLaunchIdentity = userDefaults.dictionary(forKey: "posthog.previousLaunchIdentity") ?? [:]
        self.launchStartedAt = now()
        utcHourFormatter = Self.makeUTCFormatter("yyyy-MM-dd'T'HH")
        utcDayFormatter = Self.makeUTCFormatter("yyyy-MM-dd")
        workQueue.setSpecific(key: workQueueSpecificKey, value: ())
    }

    private var isEnabled: Bool {
        // XCTest hosts can inherit the production PostHog configuration. Keep
        // test launches from initializing the SDK or sending crash telemetry.
        guard !MacSentryStartupPolicy.isRunningUnderXCTest(environment: environment) else {
            return false
        }
        guard telemetryEnabled() else { return false }
#if DEBUG
        // Avoid polluting production analytics while iterating locally.
        return environment["CMUX_POSTHOG_ENABLE"] == "1"
#else
        return !apiKey.isEmpty && apiKey != "REPLACE_WITH_POSTHOG_PUBLIC_KEY"
#endif
    }

    /// Retains the prior launch's identity before replacing it with this build.
    /// Native Ghostty envelopes do not contain the host app's version.
    func recordLaunchIdentity() {
        dispatchAsyncOnWorkQueue { [weak self] in
            guard let self else { return }
            guard !MacSentryStartupPolicy.isRunningUnderXCTest(environment: self.environment) else { return }
            guard self.telemetryEnabled() else {
                self.userDefaults.removeObject(forKey: "posthog.previousLaunchIdentity")
                return
            }
            let info = Bundle.main.infoDictionary ?? [:]
            var identity: [String: Any] = ["started_at": self.launchStartedAt]
            identity["app_version"] = info["CFBundleShortVersionString"] as? String
            identity["app_build"] = info["CFBundleVersion"] as? String
            identity["app_namespace"] = info["CFBundleIdentifier"] as? String
            self.userDefaults.set(identity, forKey: "posthog.previousLaunchIdentity")
        }
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
                self.flushPostHog()
            }
        }
    }

    /// Capture one product event with the app version properties attached.
    /// No-op when telemetry is disabled or the SDK never started. Used by the
    /// Cloud VM request telemetry (`VMClientTelemetry`).
    func capture(_ event: String, properties: [String: Any]) {
        dispatchAsyncOnWorkQueue { [weak self] in
            guard let self else { return }
            self.startIfNeededOnWorkQueue()
            guard self.didStart else { return }
            var merged = properties
            merged.merge(Self.versionProperties(infoDictionary: Bundle.main.infoDictionary ?? [:], updateChannel: self.updateChannel())) { current, _ in current }
            self.capturePostHog(event, merged)
        }
    }

    /// Mirror a previous-run crash into PostHog Error Tracking as one
    /// `$exception` event per crash. The crash is detected from the
    /// `.ghosttycrash` artifact on the next launch, so the event is sent by
    /// the reporting launch; the `crash_app_*` properties identify the build
    /// that actually crashed, which differs after an upgrade. No-op when
    /// telemetry is disabled, the SDK never started, or this crash artifact
    /// was already reported.
    func captureCrashException(pendingCrash: GhosttyCrashBreadcrumb.PendingCrash) {
        dispatchAsyncOnWorkQueue { [weak self] in
            guard let self else { return }
            self.startIfNeededOnWorkQueue()
            guard self.didStart else { return }
            // One event per crash artifact, even across relaunches that never
            // surface the crash breadcrumb notification.
            let lastReported = self.userDefaults.object(forKey: self.lastReportedCrashAtKey) as? Date ?? .distantPast
            guard pendingCrash.modifiedAt > lastReported else { return }
            self.userDefaults.set(pendingCrash.modifiedAt, forKey: self.lastReportedCrashAtKey)
            let reported = GhosttyCrashReportMetadata.reportedException(in: pendingCrash.fileURL)
            var properties = Self.crashExceptionProperties(
                reported: reported,
                infoDictionary: Bundle.main.infoDictionary ?? [:],
                updateChannel: self.updateChannel()
            )
            // Prefer the artifact's identity. A launch record only describes
            // crashes newer than that launch, never older historical files.
            if properties["crash_app_version"] == nil,
               let startedAt = self.previousLaunchIdentity["started_at"] as? Date,
               pendingCrash.modifiedAt >= startedAt {
                for key in ["app_version", "app_build", "app_namespace"] {
                    if let value = self.previousLaunchIdentity[key] as? String, !value.isEmpty {
                        properties["crash_\(key)"] = value
                    }
                }
            }
            self.capturePostHog(self.crashExceptionEvent, properties)
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

    private func startIfNeededOnWorkQueue() {
        guard !didStart else { return }
        guard isEnabled else { return }

        let config: PostHogConfig
#if DEBUG
        // A loopback collector exercises the real SDK without sending fixture
        // events to production. Release builds never accept this override.
        if let rawHost = environment["CMUX_POSTHOG_TEST_HOST"],
           let url = URL(string: rawHost),
           url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
           url.user == nil, url.password == nil {
            config = PostHogConfig(apiKey: "phc_cmux_e2e", host: rawHost)
            config.flushAt = 1
        } else {
            config = PostHogConfig(apiKey: apiKey, host: host)
        }
#else
        config = PostHogConfig(apiKey: apiKey, host: host)
#endif
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
#if DEBUG
        config.debug = ProcessInfo.processInfo.environment["CMUX_POSTHOG_DEBUG"] == "1"
#endif

        PostHogSDK.shared.setup(config)

        // Tag every event so PostHog can distinguish desktop from web and
        // break events down by released app version/build.
        PostHogSDK.shared.register(Self.superProperties(infoDictionary: Bundle.main.infoDictionary ?? [:], updateChannel: updateChannel()))

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

        let today = utcDayString(now())
        if userDefaults.string(forKey: lastActiveDayUTCKey) == today {
            return false
        }

        userDefaults.set(today, forKey: lastActiveDayUTCKey)

        let event = dailyActiveEvent

        capturePostHog(
            event,
            Self.dailyActiveProperties(
                dayUTC: today,
                reason: reason,
                infoDictionary: Bundle.main.infoDictionary ?? [:],
                updateChannel: updateChannel()
            )
        )

        if flush && Self.shouldFlushAfterCapture(event: event) {
            // For active metrics we care more about delivery than batching.
            flushPostHog()
        }

        return true
    }

    @discardableResult
    private func trackHourlyActiveOnWorkQueue(reason: String, flush: Bool) -> Bool {
        startIfNeededOnWorkQueue()
        guard didStart else { return false }

        let hour = utcHourString(now())
        if userDefaults.string(forKey: lastActiveHourUTCKey) == hour {
            return false
        }

        userDefaults.set(hour, forKey: lastActiveHourUTCKey)

        let event = hourlyActiveEvent

        capturePostHog(
            event,
            Self.hourlyActiveProperties(
                hourUTC: hour,
                reason: reason,
                infoDictionary: Bundle.main.infoDictionary ?? [:],
                updateChannel: updateChannel()
            )
        )

        if flush && Self.shouldFlushAfterCapture(event: event) {
            // Keep hourly freshness and avoid losing a deduped hour on abrupt exits.
            flushPostHog()
        }

        return true
    }

    private func dispatchAsyncOnWorkQueue(_ block: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: workQueueSpecificKey) != nil {
            block()
            return
        }
        workQueue.async(execute: block)
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

    /// Reads `updates.channel` from the shared cmux.json on every call. One store is built
    /// up front so per-event reads do not allocate a file watcher.
    nonisolated static func configFileUpdateChannelReader() -> @Sendable () -> UpdateChannel {
        let store = JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
        let key = SettingCatalog().updates.channel
        return { store.snapshotValue(for: key) }
    }

    nonisolated static func superProperties(
        infoDictionary: [String: Any],
        updateChannel: UpdateChannel = .stable
    ) -> [String: Any] {
        var properties: [String: Any] = ["platform": "cmuxterm"]
        properties.merge(versionProperties(infoDictionary: infoDictionary, updateChannel: updateChannel)) { _, new in new }
        return properties
    }

    nonisolated static func dailyActiveProperties(
        dayUTC: String,
        reason: String,
        infoDictionary: [String: Any],
        updateChannel: UpdateChannel = .stable
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "day_utc": dayUTC,
            "reason": reason,
        ]
        properties.merge(versionProperties(infoDictionary: infoDictionary, updateChannel: updateChannel)) { _, new in new }
        return properties
    }

    nonisolated static func hourlyActiveProperties(
        hourUTC: String,
        reason: String,
        infoDictionary: [String: Any],
        updateChannel: UpdateChannel = .stable
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "hour_utc": hourUTC,
            "reason": reason,
        ]
        properties.merge(versionProperties(infoDictionary: infoDictionary, updateChannel: updateChannel)) { _, new in new }
        return properties
    }

    /// PostHog Error Tracking payload for a previous-run crash. The crashed
    /// build's version/namespace come from the crash envelope (`crash_app_*`),
    /// while `versionProperties` describe the reporting launch, matching every
    /// other cmux event. The posthog-ios SDK additionally attaches its
    /// automatic `$app_version`/`$app_build`/`$app_namespace` at capture time.
    nonisolated static func crashExceptionProperties(
        reported: GhosttyCrashReportMetadata.ReportedException?,
        infoDictionary: [String: Any],
        updateChannel: UpdateChannel = .stable
    ) -> [String: Any] {
        let type = sanitizedExceptionToken(reported?.type) ?? "UnknownCrash"
        let mechanism: [String: Any] = [
            "handled": false,
            "type": sanitizedExceptionToken(reported?.mechanismType) ?? "ghostty_crash_report",
        ]
        let exception: [String: Any] = [
            "type": type,
            // Envelope reasons are arbitrary app text. Do not mirror paths,
            // commands, secrets, or customer content into analytics.
            "value": "Previous launch crashed",
            "mechanism": mechanism,
        ]
        var properties: [String: Any] = [
            "$exception_level": "error",
            // Group by crash type only; the version breakdown comes from the
            // crash_app_* and version properties, not the fingerprint.
            "$exception_fingerprint": String("cmux-mac-crash:\(type)".prefix(200)),
            "$exception_list": [exception],
        ]
        if let appVersion = reported?.appVersion, !appVersion.isEmpty {
            properties["crash_app_version"] = appVersion
        }
        if let appBuild = reported?.appBuild, !appBuild.isEmpty {
            properties["crash_app_build"] = appBuild
        }
        if let appNamespace = reported?.appNamespace, !appNamespace.isEmpty {
            properties["crash_app_namespace"] = appNamespace
        }
        properties.merge(versionProperties(infoDictionary: infoDictionary, updateChannel: updateChannel)) { _, new in new }
        return properties
    }

    /// Exception and mechanism types are identifier-like tokens; anything else
    /// collapses to nil so unexpected payloads never reach PostHog.
    nonisolated static func sanitizedExceptionToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !trimmed.isEmpty,
              trimmed.count <= 120,
              trimmed.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        return trimmed
    }

    nonisolated static func shouldFlushAfterCapture(event: String) -> Bool {
        switch event {
        case "cmux_daily_active", "cmux_hourly_active":
            return true
        default:
            return false
        }
    }

    nonisolated private static func versionProperties(
        infoDictionary: [String: Any],
        flavor: BuildFlavor = BuildFlavor.current,
        updateChannel: UpdateChannel
    ) -> [String: Any] {
        // `channel` answers "stable, RC, NIGHTLY or DEV?" for every Mac event; the
        // web side carries the same value on checkout as `checkout_channel`.
        // `update_channel` is the user's `updates.channel` feed selection: RC and
        // stable share one bundle, so `channel` alone cannot tell them apart.
        var properties: [String: Any] = [
            "channel": flavor.rawValue,
            "update_channel": updateChannel.rawValue,
        ]
        if let value = infoDictionary["CFBundleShortVersionString"] as? String, !value.isEmpty {
            properties["app_version"] = value
        }
        if let value = infoDictionary["CFBundleVersion"] as? String, !value.isEmpty {
            properties["app_build"] = value
        }
        return properties
    }
}
