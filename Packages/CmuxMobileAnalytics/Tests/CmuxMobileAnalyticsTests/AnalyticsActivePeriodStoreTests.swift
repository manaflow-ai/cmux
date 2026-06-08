import Foundation
import Testing

@testable import CmuxMobileAnalytics

@Suite struct AnalyticsActivePeriodStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "analytics-active-test-\(UUID().uuidString)")!
    }

    /// 2024-01-02T03:04:05Z — fixed instant so the UTC keys are deterministic.
    private let base = Date(timeIntervalSince1970: 1_704_164_645)

    @Test func firstClaimReturnsKeyAndIsDedupedWithinPeriod() {
        let store = AnalyticsActivePeriodStore(defaults: makeDefaults())

        #expect(store.claimDaily(now: base) == "2024-01-02")
        #expect(store.claimHourly(now: base) == "2024-01-02T03")

        // A second foreground in the same UTC day/hour must not re-emit.
        #expect(store.claimDaily(now: base.addingTimeInterval(5 * 60)) == nil)
        #expect(store.claimHourly(now: base.addingTimeInterval(5 * 60)) == nil)
    }

    @Test func hourlyReclaimsAcrossHourBoundaryButDailyDoesNot() {
        let store = AnalyticsActivePeriodStore(defaults: makeDefaults())
        _ = store.claimDaily(now: base)
        _ = store.claimHourly(now: base)

        // One hour later (still the same UTC day): hourly re-claims, daily stays
        // suppressed.
        let nextHour = base.addingTimeInterval(60 * 60)
        #expect(store.claimDaily(now: nextHour) == nil)
        #expect(store.claimHourly(now: nextHour) == "2024-01-02T04")
    }

    @Test func bothReclaimAcrossDayBoundary() {
        let store = AnalyticsActivePeriodStore(defaults: makeDefaults())
        _ = store.claimDaily(now: base)
        _ = store.claimHourly(now: base)

        let nextDay = base.addingTimeInterval(24 * 60 * 60)
        #expect(store.claimDaily(now: nextDay) == "2024-01-03")
        #expect(store.claimHourly(now: nextDay) == "2024-01-03T03")
    }

    @Test func dedupSurvivesRelaunch() {
        let defaults = makeDefaults()
        let store = AnalyticsActivePeriodStore(defaults: defaults)
        #expect(store.claimDaily(now: base) == "2024-01-02")
        #expect(store.claimHourly(now: base) == "2024-01-02T03")

        // A fresh store backed by the same defaults (a relaunch) sees the period
        // as already claimed and does not re-emit.
        let reread = AnalyticsActivePeriodStore(defaults: defaults)
        #expect(reread.claimDaily(now: base) == nil)
        #expect(reread.claimHourly(now: base) == nil)
    }

    @Test func formattersUseUTCRegardlessOfHostTimeZone() {
        // The keys are UTC-stable, independent of the device's local zone.
        #expect(AnalyticsActivePeriodStore.dayUTCString(base) == "2024-01-02")
        #expect(AnalyticsActivePeriodStore.hourUTCString(base) == "2024-01-02T03")
    }
}
