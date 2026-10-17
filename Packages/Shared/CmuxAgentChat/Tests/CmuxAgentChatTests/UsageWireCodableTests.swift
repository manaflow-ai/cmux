import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Usage wire compatibility")
struct UsageWireCodableTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("history usage is optional for older hosts and round-trips new values")
    func historyUsageRoundTripAndLegacyDecode() throws {
        let usage = ChatUsageTotals(
            usage: ChatTokenUsage(freshInputTokens: 120, outputTokens: 80),
            contextTokens: 320,
            contextWindowTokens: 1_000,
            rateLimit: ChatUsageRateLimit(
                primary: .init(usedPercent: 12.5, windowMinutes: 300),
                spendControlReached: false
            )
        )
        let page = ChatHistoryPage(messages: [], hasMore: false, usage: usage)
        let data = try encoder.encode(page)
        #expect(String(decoding: data, as: UTF8.self).contains("\"usage\""))
        #expect(try decoder.decode(ChatHistoryPage.self, from: data).usage == usage)

        let legacy = Data(#"{"messages":[],"has_more":false}"#.utf8)
        #expect(try decoder.decode(ChatHistoryPage.self, from: legacy).usage == nil)
    }

    @Test("usage event is additive and preserves rate-limit reset dates")
    func usageEventRoundTrip() throws {
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = ChatUsageTotals(
            contextTokens: 1_200,
            contextWindowTokens: 4_000,
            rateLimit: ChatUsageRateLimit(
                secondary: .init(usedPercent: 88, resetsAt: reset),
                spendControlReached: true
            )
        )
        let event = ChatSessionEvent.usageChanged(usage)
        let data = try encoder.encode(event)
        #expect(String(decoding: data, as: UTF8.self).contains("\"usage_changed\""))
        #expect(try decoder.decode(ChatSessionEvent.self, from: data) == event)
    }

    @Test("unknown usage event remains ignorable for an old decoder")
    func unknownUsageEventIsRepresentedExplicitly() throws {
        let data = Data(#"{"event":"usage_changed","usage":{}}"#.utf8)
        #expect(try decoder.decode(ChatSessionEvent.self, from: data) == .usageChanged(ChatUsageTotals()))
    }
}
