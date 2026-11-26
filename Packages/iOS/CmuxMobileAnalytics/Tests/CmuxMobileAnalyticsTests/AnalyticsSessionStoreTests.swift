import Foundation
import Testing

@testable import CmuxMobileAnalytics

@Suite struct AnalyticsSessionStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "analytics-session-test-\(UUID().uuidString)")!
        return suite
    }

    @Test func freshStoreReportsNoSession() {
        let store = AnalyticsSessionStore(defaults: makeDefaults())
        #expect(store.currentSessionID == nil)
        #expect(store.lastBackgroundedAt == nil)
    }

    @Test func roundTripsSessionIDAndBackgroundTimestamp() {
        let defaults = makeDefaults()
        let store = AnalyticsSessionStore(defaults: defaults)
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1_234_567)
        store.setCurrentSessionID(id)
        store.recordBackgrounded(at: when)
        let reread = AnalyticsSessionStore(defaults: defaults)
        #expect(reread.currentSessionID == id)
        #expect(reread.lastBackgroundedAt == when)
    }

    @Test func endToEndSessionizationAcrossLaunches() {
        let defaults = makeDefaults()
        let store = AnalyticsSessionStore(defaults: defaults)
        let sessionizer = AnalyticsSessionizer(inactivityWindow: 30 * 60)
        let base = Date(timeIntervalSince1970: 2_000_000)

        // Cold start: new session.
        let cold = sessionizer.resolveForeground(
            now: base,
            lastBackgroundedAt: store.lastBackgroundedAt,
            currentSessionID: store.currentSessionID
        )
        #expect(cold.startedNewSession)
        store.setCurrentSessionID(cold.sessionID)

        // Background then quick resume: same session.
        store.recordBackgrounded(at: base.addingTimeInterval(60))
        let warm = sessionizer.resolveForeground(
            now: base.addingTimeInterval(120),
            lastBackgroundedAt: store.lastBackgroundedAt,
            currentSessionID: store.currentSessionID
        )
        #expect(!warm.startedNewSession)
        #expect(warm.sessionID == cold.sessionID)

        // Background then long gap: new session.
        store.recordBackgrounded(at: base.addingTimeInterval(200))
        let resumed = sessionizer.resolveForeground(
            now: base.addingTimeInterval(200 + 31 * 60),
            lastBackgroundedAt: store.lastBackgroundedAt,
            currentSessionID: store.currentSessionID
        )
        #expect(resumed.startedNewSession)
        #expect(resumed.sessionID != cold.sessionID)
    }
}
