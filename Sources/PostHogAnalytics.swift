import AppKit
import Foundation
import os

/// The two desktop activity metrics sent to PostHog.
///
/// cmux intentionally owns this tiny transport instead of linking the PostHog
/// client SDK. The SDK bundled replay, surveys, and UI implementation that
/// the desktop app did not use. This actor keeps mutable scheduling and dedupe
/// state isolated while URLSession performs delivery asynchronously.
actor PostHogAnalytics {
    struct Event: Sendable, Equatable {
        let name: String
        let properties: [String: String]
        let timestamp: Date
    }

    typealias CaptureEvents = @Sendable (
        _ events: [Event],
        _ distinctID: String,
        _ apiKey: String,
        _ host: URL
    ) async -> Void

    static let shared = PostHogAnalytics()

    // The PostHog project API key is intentionally embedded in the app. It is
    // the same public project key shipped by the web client.
    private let apiKey = "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP"
    private let host = URL(string: "https://us.i.posthog.com")!

    private let dailyActiveEvent = "cmux_daily_active"
    private let hourlyActiveEvent = "cmux_hourly_active"
    private let lastActiveDayUTCKey = "posthog.lastActiveDayUTC"
    private let lastActiveHourUTCKey = "posthog.lastActiveHourUTC"
    private let distinctIDKey = "posthog.desktopDistinctID"

    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private let captureEvents: CaptureEvents
    private var didStart: Bool
    private var activeCheckTask: Task<Void, Never>?

    private init(
        didStart: Bool = false,
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        captureEvents: @escaping CaptureEvents = { events, distinctID, apiKey, host in
            await PostHogAnalytics.deliver(
                events: events,
                distinctID: distinctID,
                apiKey: apiKey,
                host: host
            )
        }
    ) {
        self.didStart = didStart
        self.userDefaults = userDefaults
        self.now = now
        self.captureEvents = captureEvents
    }

    deinit {
        activeCheckTask?.cancel()
    }

#if DEBUG
    static func makeForTesting(
        didStart: Bool,
        userDefaults: UserDefaults,
        now: @escaping @Sendable () -> Date,
        captureEvents: @escaping CaptureEvents
    ) -> PostHogAnalytics {
        PostHogAnalytics(
            didStart: didStart,
            userDefaults: userDefaults,
            now: now,
            captureEvents: captureEvents
        )
    }
#endif

    func startIfNeeded() {
        guard !didStart, Self.isEnabled else { return }
        didStart = true
        scheduleActiveCheck()
    }

    func trackActive(reason: String) async {
        startIfNeeded()
        guard didStart else { return }

        let date = now()
        var events: [Event] = []
        if let event = dailyActiveEventIfNeeded(reason: reason, date: date) {
            events.append(event)
        }
        if let event = hourlyActiveEventIfNeeded(reason: reason, date: date) {
            events.append(event)
        }
        await deliver(events)
    }

    func trackDailyActive(reason: String) async {
        startIfNeeded()
        guard didStart,
              let event = dailyActiveEventIfNeeded(reason: reason, date: now())
        else { return }
        await deliver([event])
    }

    func trackHourlyActive(reason: String) async {
        startIfNeeded()
        guard didStart,
              let event = hourlyActiveEventIfNeeded(reason: reason, date: now())
        else { return }
        await deliver([event])
    }

    private func scheduleActiveCheck() {
        guard activeCheckTask == nil else { return }
        activeCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30 * 60))
                } catch {
                    return
                }
                guard await MainActor.run(body: { NSApp.isActive }) else { continue }
                await self?.trackActive(reason: "activeTimer")
            }
        }
    }

    private func dailyActiveEventIfNeeded(reason: String, date: Date) -> Event? {
        let today = Self.utcString(date, format: "yyyy-MM-dd")
        guard userDefaults.string(forKey: lastActiveDayUTCKey) != today else { return nil }
        userDefaults.set(today, forKey: lastActiveDayUTCKey)
        return Event(
            name: dailyActiveEvent,
            properties: Self.dailyActiveProperties(
                dayUTC: today,
                reason: reason,
                infoDictionary: Bundle.main.infoDictionary ?? [:]
            ),
            timestamp: date
        )
    }

    private func hourlyActiveEventIfNeeded(reason: String, date: Date) -> Event? {
        let hour = Self.utcString(date, format: "yyyy-MM-dd'T'HH")
        guard userDefaults.string(forKey: lastActiveHourUTCKey) != hour else { return nil }
        userDefaults.set(hour, forKey: lastActiveHourUTCKey)
        return Event(
            name: hourlyActiveEvent,
            properties: Self.hourlyActiveProperties(
                hourUTC: hour,
                reason: reason,
                infoDictionary: Bundle.main.infoDictionary ?? [:]
            ),
            timestamp: date
        )
    }

    private func deliver(_ events: [Event]) async {
        guard !events.isEmpty else { return }
        await captureEvents(events, distinctID(), apiKey, host)
    }

    private func distinctID() -> String {
        if let existing = userDefaults.string(forKey: distinctIDKey),
           existing.hasPrefix("cmux-desktop-"),
           UUID(uuidString: String(existing.dropFirst("cmux-desktop-".count))) != nil {
            return existing
        }
        let value = "cmux-desktop-" + UUID().uuidString.lowercased()
        userDefaults.set(value, forKey: distinctIDKey)
        return value
    }

    nonisolated static func batchRequest(
        events: [Event],
        distinctID: String,
        apiKey: String,
        host: URL
    ) -> URLRequest? {
        guard !events.isEmpty,
              let url = URL(string: "batch/", relativeTo: host)?.absoluteURL
        else { return nil }

        let batch: [[String: Any]] = events.map { event in
            var properties: [String: Any] = event.properties
            properties["distinct_id"] = distinctID
            return [
                "event": event.name,
                "distinct_id": distinctID,
                "properties": properties,
                "timestamp": event.timestamp.ISO8601Format(.iso8601.dateTimeSeparator(.standard)),
            ]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "api_key": apiKey,
            "batch": batch,
        ]) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    nonisolated private static func deliver(
        events: [Event],
        distinctID: String,
        apiKey: String,
        host: URL
    ) async {
        guard let request = batchRequest(
            events: events,
            distinctID: distinctID,
            apiKey: apiKey,
            host: host
        ) else { return }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                Logger.postHog.error("activity batch rejected")
                return
            }
        } catch is CancellationError {
            return
        } catch {
            Logger.postHog.error("activity batch failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    nonisolated private static var isEnabled: Bool {
        guard TelemetrySettings.enabledForCurrentLaunch else { return false }
#if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_POSTHOG_ENABLE"] == "1"
#else
        return true
#endif
    }

    nonisolated static func superProperties(infoDictionary: [String: Any]) -> [String: String] {
        var properties = ["platform": "cmuxterm"]
        properties.merge(versionProperties(infoDictionary: infoDictionary)) { _, new in new }
        return properties
    }

    nonisolated static func dailyActiveProperties(
        dayUTC: String,
        reason: String,
        infoDictionary: [String: Any]
    ) -> [String: String] {
        var properties = [
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
    ) -> [String: String] {
        var properties = [
            "hour_utc": hourUTC,
            "reason": reason,
        ]
        properties.merge(versionProperties(infoDictionary: infoDictionary)) { _, new in new }
        return properties
    }

    nonisolated private static func versionProperties(
        infoDictionary: [String: Any]
    ) -> [String: String] {
        var properties: [String: String] = [:]
        if let value = infoDictionary["CFBundleShortVersionString"] as? String, !value.isEmpty {
            properties["app_version"] = value
        }
        if let value = infoDictionary["CFBundleVersion"] as? String, !value.isEmpty {
            properties["app_build"] = value
        }
        return properties
    }

    nonisolated private static func utcString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

private extension Logger {
    static let postHog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm", category: "analytics")
}
