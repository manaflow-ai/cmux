import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileAnalytics

@Suite @MainActor struct MobileFeedPerformanceReporterTests {
    private final class Clock {
        var seconds = 0.0
    }

    @Test func measuresOnlyScrollIntervalsAndDefersSentryUntilIdle() async throws {
        let uploader = RecordingAnalyticsUploader()
        let consent = AnalyticsConsentProvider { true }
        let emitter = AnalyticsEmitter(uploader: uploader, consent: consent, anonymousID: "test")
        let clock = Clock()
        var incidents: [MobileFeedScrollAnomaly] = []
        let reporter = MobileFeedPerformanceReporter(
            emitter: emitter, consent: consent, cadence: .seconds(3_600), now: { clock.seconds },
            onAnomaly: { incidents.append($0); return String(repeating: "a", count: 32) }
        )
        reporter.setEnabled(true)
        reporter.setVisible(true, itemCount: 400)
        reporter.callback(at: 0, expectedInterval: 1 / 60)
        reporter.setScrolling(true)
        reporter.callback(at: 100, expectedInterval: 1 / 120)
        reporter.callback(at: 100.008, expectedInterval: 1 / 120)
        reporter.callback(at: 100.128, expectedInterval: 1 / 60)
        clock.seconds = 10
        reporter.updateCompleted(stage: .apply, startedAt: 9.990, endedAt: 10, itemCount: 400)
        reporter.updateCompleted(stage: .projection, startedAt: 9.974, endedAt: 10, itemCount: 400)
        await reporter.flush()
        #expect(incidents.isEmpty)
        reporter.setScrolling(false)
        await emitter.flush()
        let events = await uploader.uploadedEvents
        let window = try #require(events.first { $0.name == "ios_feed_performance_window" })
        let anomaly = try #require(events.first { $0.name == "ios_feed_scroll_anomaly" })
        #expect(window.properties["callback_count"] == .int(2))
        #expect(window.properties["callback_budget_histogram"] == .string("[0,1,1,0,0,0,0,0,0,0]"))
        #expect(window.properties["gaps_over_100ms"] == .int(1))
        #expect(window.properties["updates_while_scrolling"] == .int(1))
        #expect(window.properties["projection_histogram"] == .string("[0,0,0,0,1,0,0,0,0,0]"))
        #expect(anomaly.properties["window_id"] == window.properties["window_id"])
        #expect(anomaly.properties["sentry_event_id"] == .string(String(repeating: "a", count: 32)))
        #expect(incidents.count == 1)

        reporter.setScrolling(true)
        reporter.callback(at: 500, expectedInterval: 1 / 60)
        reporter.callback(at: 500.016, expectedInterval: 1 / 60)
        await reporter.flush()
        let last = try #require(await uploader.uploadedEvents.last)
        #expect(last.properties["callback_count"] == .int(1))
        #expect(last.properties["gaps_over_100ms"] == .int(0))
    }

    @Test func backgroundAndHiddenWorkCannotBecomeScrollOrUpdateSamples() async throws {
        let uploader = RecordingAnalyticsUploader()
        let consent = AnalyticsConsentProvider { true }
        let emitter = AnalyticsEmitter(uploader: uploader, consent: consent, anonymousID: "test")
        let clock = Clock()
        let reporter = MobileFeedPerformanceReporter(
            emitter: emitter, consent: consent, cadence: .seconds(3_600), now: { clock.seconds }
        )
        reporter.setEnabled(true)
        reporter.setVisible(true, itemCount: 400)
        reporter.setScrolling(true)
        reporter.callback(at: 0, expectedInterval: 1 / 60)
        reporter.setForeground(false)
        clock.seconds = 90
        reporter.callback(at: 90, expectedInterval: 1 / 60)
        reporter.setForeground(true)
        reporter.updateCompleted(stage: .decode, startedAt: 1, endedAt: 90, itemCount: 400)
        reporter.setScrolling(true)
        reporter.callback(at: 91, expectedInterval: 1 / 60)
        reporter.callback(at: 91.016, expectedInterval: 1 / 60)
        reporter.setVisible(false, itemCount: 400)
        reporter.updateCompleted(stage: .apply, startedAt: 89, endedAt: 90, itemCount: 400)
        await reporter.flush()
        let events = await uploader.uploadedEvents
        #expect(events.count == 1)
        #expect(events.first?.properties["callback_count"] == .int(1))
        #expect(events.first?.properties["decode_histogram"] == .string("[0,0,0,0,0,0,0,0,0,0]"))
        #expect(!reporter.isSamplingEnabled)
    }

    @Test func rapidConsentRevocationAndReenableDiscardsOldWindowAndIncident() async throws {
        let suite = "feed-perf-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        let consent = UserDefaultsAnalyticsConsentProvider(defaults: defaults)
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader, consent: consent, anonymousID: "test", notificationCenter: center
        )
        var incidents = 0
        let clock = Clock()
        let reporter = MobileFeedPerformanceReporter(
            emitter: emitter, consent: consent, notificationCenter: center,
            cadence: .seconds(3_600), now: { clock.seconds }, onAnomaly: { _ in incidents += 1; return nil }
        )
        reporter.setEnabled(true)
        reporter.setVisible(true, itemCount: 400)
        reporter.setScrolling(true)
        reporter.callback(at: 0, expectedInterval: 1 / 60)
        reporter.callback(at: 0.200, expectedInterval: 1 / 60)
        defaults.set(false, forKey: "sendAnonymousTelemetry")
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(!reporter.isSamplingEnabled)
        defaults.set(true, forKey: "sendAnonymousTelemetry")
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        // No actor yield between revoke and re-enable: the generation gate must
        // reject old samples even if the async notification consumer is late.
        reporter.setScrolling(false)
        clock.seconds = 1
        reporter.updateCompleted(stage: .apply, startedAt: 0.999, endedAt: 1, itemCount: 1)
        await reporter.flush()
        let events = await uploader.uploadedEvents
        #expect(incidents == 0)
        #expect(events.count == 1)
        #expect(events.first?.properties["callback_count"] == .int(0))
        #expect(events.first?.properties["apply_histogram"] == .string("[1,0,0,0,0,0,0,0,0,0]"))
    }

    @Test func rolloutGateDefaultsOffAndIncidentBudgetIsOnePerMinute() async throws {
        let uploader = RecordingAnalyticsUploader()
        let consent = AnalyticsConsentProvider { true }
        let emitter = AnalyticsEmitter(uploader: uploader, consent: consent, anonymousID: "test")
        let clock = Clock()
        var incidents = 0
        let reporter = MobileFeedPerformanceReporter(
            emitter: emitter, consent: consent, cadence: .seconds(3_600), now: { clock.seconds },
            onAnomaly: { _ in incidents += 1; return nil }
        )
        reporter.setVisible(true, itemCount: 400)
        #expect(!reporter.isSamplingEnabled)
        reporter.setEnabled(true)
        for seconds in [0.0, 20, 61] {
            clock.seconds = seconds
            reporter.setScrolling(true)
            reporter.callback(at: seconds, expectedInterval: 1 / 60)
            reporter.callback(at: seconds + 0.2, expectedInterval: 1 / 60)
            await reporter.flush()
            reporter.setScrolling(false)
        }
        #expect(incidents == 2)
        reporter.setScrolling(true)
        reporter.callback(at: 100, expectedInterval: 1 / 60)
        reporter.callback(at: 101, expectedInterval: 1 / 60)
        reporter.setEnabled(false)
        reporter.setEnabled(true)
        await reporter.flush()
        #expect(incidents == 2)
    }

    @Test func itemCountsDoNotCarryEarlierWindowPeaksIntoSmallerFeeds() async throws {
        let uploader = RecordingAnalyticsUploader()
        let consent = AnalyticsConsentProvider { true }
        let emitter = AnalyticsEmitter(uploader: uploader, consent: consent, anonymousID: "test")
        let reporter = MobileFeedPerformanceReporter(
            emitter: emitter, consent: consent, cadence: .seconds(3_600)
        )
        reporter.setEnabled(true)
        reporter.setVisible(true, itemCount: 400)
        reporter.setScrolling(true)
        reporter.callback(at: 0, expectedInterval: 1 / 60)
        reporter.callback(at: 0.016, expectedInterval: 1 / 60)
        reporter.setVisible(true, itemCount: 3)
        await reporter.flush()
        reporter.setScrolling(false)

        reporter.setScrolling(true)
        reporter.callback(at: 1, expectedInterval: 1 / 60)
        reporter.callback(at: 1.016, expectedInterval: 1 / 60)
        await reporter.flush()
        reporter.setVisible(false, itemCount: 3)

        reporter.setVisible(true, itemCount: 2)
        reporter.setScrolling(true)
        reporter.callback(at: 2, expectedInterval: 1 / 60)
        reporter.callback(at: 2.016, expectedInterval: 1 / 60)
        await reporter.flush()
        let counts = await uploader.uploadedEvents
            .filter { $0.name == "ios_feed_performance_window" }
            .compactMap { $0.properties["item_count"] }
        #expect(counts == [.int(400), .int(3), .int(2)])
    }

    @Test func enablingTelemetryKeepsTheAlreadyVisibleFeedCount() async throws {
        let uploader = RecordingAnalyticsUploader()
        let consent = AnalyticsConsentProvider { true }
        let emitter = AnalyticsEmitter(uploader: uploader, consent: consent, anonymousID: "test")
        let reporter = MobileFeedPerformanceReporter(
            emitter: emitter, consent: consent, cadence: .seconds(3_600)
        )
        reporter.setVisible(true, itemCount: 400)
        reporter.setEnabled(true)
        reporter.setScrolling(true)
        reporter.callback(at: 0, expectedInterval: 1 / 60)
        reporter.callback(at: 0.016, expectedInterval: 1 / 60)
        await reporter.flush()
        let event = try #require(await uploader.uploadedEvents.first)
        #expect(event.properties["item_count"] == .int(400))
    }

    @Test func histogramHasFixedStorageAndRejectsNonfiniteValues() {
        var histogram = MobileFeedTimingHistogram()
        histogram.record(seconds: .nan)
        histogram.record(seconds: .infinity)
        histogram.record(seconds: -1)
        histogram.record(seconds: 600)
        #expect(histogram.count == 1)
        #expect(histogram.maximumMilliseconds == 60_000)
        #expect(histogram.encoded == "[0,0,0,0,0,0,0,0,0,1]")
    }
}
