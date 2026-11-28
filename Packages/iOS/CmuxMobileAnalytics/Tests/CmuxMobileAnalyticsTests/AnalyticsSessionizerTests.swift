import Foundation
import Testing

@testable import CmuxMobileAnalytics

@Suite struct AnalyticsSessionizerTests {
    private let sessionizer = AnalyticsSessionizer(inactivityWindow: 30 * 60)
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func coldStartStartsNewSession() {
        let next = UUID()
        let decision = sessionizer.resolveForeground(
            now: base,
            lastBackgroundedAt: nil,
            currentSessionID: nil,
            newSessionID: next
        )
        #expect(decision.startedNewSession)
        #expect(decision.sessionID == next)
        #expect(decision.secondsSinceBackgrounded == nil)
    }

    @Test func resumeWithinWindowContinuesSession() {
        let current = UUID()
        let decision = sessionizer.resolveForeground(
            now: base.addingTimeInterval(10 * 60),
            lastBackgroundedAt: base,
            currentSessionID: current,
            newSessionID: UUID()
        )
        #expect(!decision.startedNewSession)
        #expect(decision.sessionID == current)
        #expect(decision.secondsSinceBackgrounded == Double(10 * 60))
    }

    @Test func resumePastWindowStartsNewSession() {
        let current = UUID()
        let next = UUID()
        let decision = sessionizer.resolveForeground(
            now: base.addingTimeInterval(31 * 60),
            lastBackgroundedAt: base,
            currentSessionID: current,
            newSessionID: next
        )
        #expect(decision.startedNewSession)
        #expect(decision.sessionID == next)
        #expect(decision.secondsSinceBackgrounded == Double(31 * 60))
    }

    @Test func exactlyAtWindowBoundaryContinues() {
        let current = UUID()
        let decision = sessionizer.resolveForeground(
            now: base.addingTimeInterval(30 * 60),
            lastBackgroundedAt: base,
            currentSessionID: current,
            newSessionID: UUID()
        )
        // Boundary is inclusive of the existing session (gap must *exceed* window).
        #expect(!decision.startedNewSession)
        #expect(decision.sessionID == current)
    }

    @Test func missingBackgroundTimestampStartsNewSession() {
        let decision = sessionizer.resolveForeground(
            now: base,
            lastBackgroundedAt: nil,
            currentSessionID: UUID(),
            newSessionID: UUID()
        )
        #expect(decision.startedNewSession)
    }
}
