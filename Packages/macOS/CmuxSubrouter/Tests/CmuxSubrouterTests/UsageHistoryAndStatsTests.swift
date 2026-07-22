import Foundation
import Testing
@testable import CmuxSubrouter

@Suite struct UsageHistoryTests {
    private func account(
        id: String,
        used: Double,
        provider: SubrouterProvider = .codex
    ) -> SubrouterAccountUsageStatus {
        SubrouterAccountUsageStatus(
            id: id,
            provider: provider,
            email: id,
            authChecked: true,
            authValid: true,
            windows: [
                SubrouterUsageWindow(
                    name: "5h",
                    usedPercent: used,
                    limitWindowSeconds: 18_000,
                    resetAfterSeconds: 3600,
                    feature: ""
                ),
            ]
        )
    }

    @Test func recordsFirstSampleAndThrottlesUnchangedFollowups() {
        var history = SubrouterUsageHistory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        let first = history.record(usageStatuses: [account(id: "a", used: 40)], now: base)
        #expect(first)
        // Same value 1 minute later: throttled.
        let throttled = history.record(usageStatuses: [account(id: "a", used: 40.2)], now: base.addingTimeInterval(60))
        #expect(!throttled)
        // Significant movement records despite spacing.
        let moved = history.record(usageStatuses: [account(id: "a", used: 45)], now: base.addingTimeInterval(120))
        #expect(moved)
        // Spacing elapsed records even without movement.
        let spaced = history.record(usageStatuses: [account(id: "a", used: 45)], now: base.addingTimeInterval(120 + 601))
        #expect(spaced)
        let samples = history.samples(provider: .codex, accountID: "a", windowName: "5h")
        #expect(samples.map(\.usedPercent) == [40, 45, 45])
    }

    @Test func scopesSeriesByProvider() {
        var history = SubrouterUsageHistory()
        let base = Date(timeIntervalSince1970: 1_500_000)
        // The same account ID under two providers (a Codex email and a
        // Claude profile name can collide) must keep separate series.
        _ = history.record(
            usageStatuses: [
                account(id: "a", used: 40, provider: .codex),
                account(id: "a", used: 80, provider: .claude),
            ],
            now: base
        )
        #expect(history.samples(provider: .codex, accountID: "a", windowName: "5h").map(\.usedPercent) == [40])
        #expect(history.samples(provider: .claude, accountID: "a", windowName: "5h").map(\.usedPercent) == [80])
    }

    @Test func evictsSeriesForAccountsThatDisappear() {
        var history = SubrouterUsageHistory()
        let base = Date(timeIntervalSince1970: 1_600_000)
        _ = history.record(usageStatuses: [account(id: "removed", used: 10)], now: base)
        // A refresh after the retention window that no longer includes the
        // old account prunes its series entirely, keeping the persisted
        // file bounded over the life of an install.
        let later = base.addingTimeInterval(SubrouterUsageHistory.retention + 60)
        let changed = history.record(usageStatuses: [account(id: "kept", used: 20)], now: later)
        #expect(changed)
        #expect(history.samples(provider: .codex, accountID: "removed", windowName: "5h").isEmpty)
        #expect(history.samples(provider: .codex, accountID: "kept", windowName: "5h").count == 1)
    }

    @Test func capsTotalSeriesCount() {
        var history = SubrouterUsageHistory()
        let base = Date(timeIntervalSince1970: 1_700_000)
        // Oldest-by-newest-sample series fall off past the global cap.
        for index in 0..<(SubrouterUsageHistory.maximumSeriesCount + 10) {
            _ = history.record(
                usageStatuses: [account(id: "acct-\(index)", used: 50)],
                now: base.addingTimeInterval(Double(index))
            )
        }
        #expect(history.samples(provider: .codex, accountID: "acct-0", windowName: "5h").isEmpty)
        #expect(!history.samples(
            provider: .codex,
            accountID: "acct-\(SubrouterUsageHistory.maximumSeriesCount + 9)",
            windowName: "5h"
        ).isEmpty)
    }

    @Test func capsAndPrunesSeries() {
        var history = SubrouterUsageHistory()
        let base = Date(timeIntervalSince1970: 2_000_000)
        for index in 0..<120 {
            _ = history.record(
                usageStatuses: [account(id: "a", used: Double(index % 100))],
                now: base.addingTimeInterval(Double(index) * 700)
            )
        }
        let samples = history.samples(provider: .codex, accountID: "a", windowName: "5h")
        #expect(samples.count <= SubrouterUsageHistory.maximumSamplesPerSeries)
        #expect(samples.first!.recordedAt > base)
    }

    @Test func persistsRoundTrip() throws {
        var history = SubrouterUsageHistory()
        _ = history.record(usageStatuses: [account(id: "a", used: 33)], now: Date(timeIntervalSince1970: 3_000_000))
        let url = URL.temporaryDirectory
            .appendingPathComponent("cmux-subrouter-history-test-\(UUID().uuidString)/history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        history.save(to: url)
        let loaded = SubrouterUsageHistory.load(from: url)
        #expect(loaded == history)
        #expect(SubrouterUsageHistory.load(from: url.appendingPathExtension("missing")) == SubrouterUsageHistory())
    }
}

@Suite struct SessionStatsTests {
    private func session(
        _ account: String,
        agedSeconds: TimeInterval,
        now: Date,
        agentType: String = "codex"
    ) -> SubrouterSessionAssignment {
        SubrouterSessionAssignment(
            agentType: agentType,
            sessionID: UUID().uuidString,
            accountID: account,
            userEmail: nil,
            createdAt: now.addingTimeInterval(-agedSeconds - 60),
            updatedAt: now.addingTimeInterval(-agedSeconds)
        )
    }

    @Test func countsWithinWindowSortedByActivity() {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let sessions = [
            session("a", agedSeconds: 100, now: now),
            session("a", agedSeconds: 200, now: now),
            session("b", agedSeconds: 50, now: now),
            session("stale", agedSeconds: 9 * 24 * 3600, now: now),
        ]
        let activity = SubrouterSessionStats.accountActivity(
            sessions: sessions,
            window: 7 * 24 * 3600,
            now: now
        )
        #expect(activity.map(\.accountID) == ["a", "b"])
        #expect(activity[0].sessionCount == 2)
        #expect(activity[1].sessionCount == 1)
    }

    @Test func scopesActivityByAgentType() {
        // The same account ID under two agent types must stay two rows
        // (same identity rule as the provider-scoped usage-history keys).
        let now = Date(timeIntervalSince1970: 4_100_000)
        let sessions = [
            session("a", agedSeconds: 100, now: now, agentType: "codex"),
            session("a", agedSeconds: 90, now: now, agentType: "codex"),
            session("a", agedSeconds: 80, now: now, agentType: "claude"),
        ]
        let activity = SubrouterSessionStats.accountActivity(
            sessions: sessions,
            window: 7 * 24 * 3600,
            now: now
        )
        #expect(activity.count == 2)
        #expect(activity[0].agentType == "codex")
        #expect(activity[0].sessionCount == 2)
        #expect(activity[1].agentType == "claude")
        #expect(activity[1].sessionCount == 1)
        #expect(Set(activity.map(\.id)).count == 2)
    }
}

@Suite struct HeadroomOrderingTests {
    private func account(id: String, usedPercents: [Double]) -> SubrouterAccountUsageStatus {
        SubrouterAccountUsageStatus(
            id: id,
            provider: .codex,
            authChecked: true,
            authValid: true,
            windows: usedPercents.enumerated().map { index, used in
                SubrouterUsageWindow(
                    name: "w\(index)",
                    usedPercent: used,
                    limitWindowSeconds: 18_000,
                    resetAfterSeconds: 3600,
                    feature: ""
                )
            }
        )
    }

    @Test func constrainingWindowIsMostConsumed() {
        let status = account(id: "a", usedPercents: [12, 88, 40])
        #expect(status.constrainingWindow?.name == "w1")
        #expect(account(id: "b", usedPercents: []).constrainingWindow == nil)
    }

    @Test func sortsMostHeadroomFirstWithNoDataLast() {
        let sorted = SubrouterAccountUsageStatus.sortedByHeadroom([
            account(id: "hot", usedPercents: [10, 90]),
            account(id: "unknown", usedPercents: []),
            account(id: "cool", usedPercents: [15]),
            account(id: "warm", usedPercents: [55, 20]),
        ])
        #expect(sorted.map(\.id) == ["cool", "warm", "hot", "unknown"])
    }

    @Test func breaksTiesByIDForStableOrder() {
        let sorted = SubrouterAccountUsageStatus.sortedByHeadroom([
            account(id: "b", usedPercents: [50]),
            account(id: "a", usedPercents: [50]),
            account(id: "d", usedPercents: []),
            account(id: "c", usedPercents: []),
        ])
        #expect(sorted.map(\.id) == ["a", "b", "c", "d"])
    }
}
