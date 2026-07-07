#if DEBUG
import CmuxAgentChat
import Foundation

extension AgentChatDemoScreen {
    /// `CMUX_UITEST_CHAT_FIXTURE_REPEAT` repeats the fixture conversation so UI
    /// tests can exercise long transcripts (paging and far scroll-to-bottom).
    /// Read directly from the environment because the inline chat preview launches
    /// with `CMUX_UITEST_MOCK_DATA=0`, which disables mock-gated UITestConfig values.
    static var fixtureRepeatCount: Int {
        let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_CHAT_FIXTURE_REPEAT"]
        return max(1, raw.flatMap(Int.init) ?? 1)
    }

    /// Rebuilds `base` repeated `count` times with fresh ids, ascending seq, and a
    /// monotonic timeline ending near now, so paging and date headers stay sane.
    static func repeatedFixtureMessages(_ base: [ChatMessage], count: Int) -> [ChatMessage] {
        guard count > 1 else { return base }
        let total = base.count * count
        let start = Date().addingTimeInterval(-Double(total) * 10)
        var messages: [ChatMessage] = []
        messages.reserveCapacity(total)
        for copy in 0..<count {
            for message in base {
                messages.append(
                    ChatMessage(
                        id: "fixture-\(copy)-\(message.seq)",
                        seq: messages.count,
                        role: message.role,
                        timestamp: start.addingTimeInterval(Double(messages.count) * 10),
                        kind: message.kind
                    )
                )
            }
        }
        return messages
    }
}
#endif
