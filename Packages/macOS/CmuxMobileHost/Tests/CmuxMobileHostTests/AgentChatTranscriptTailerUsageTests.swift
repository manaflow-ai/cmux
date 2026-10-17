@testable import CmuxMobileHost
import CmuxAgentChat
import Foundation
import Testing

struct AgentChatTranscriptTailerUsageTests {
    @Test func historyCarriesCodexContextAndRateLimitUsage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"turn_context","payload":{"turn_id":"turn-1","thread_id":"thread-1","model":"gpt-6-codex"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1000},"model_context_window":4000},"rate_limits":{"primary":{"used_percent":25,"window_minutes":300}}}}"#,
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)

        let tailer = AgentChatTranscriptTailer(
            sessionID: "usage-session",
            agentKind: .codex,
            path: url.path,
            onBatch: { _ in }
        )
        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 20)
        await tailer.stop()

        #expect(page.usage?.contextTokens == 980)
        #expect(page.usage?.contextWindowTokens == 4_000)
        #expect(page.usage?.rateLimit?.primary?.usedPercent == 25)
        #expect(page.usage?.usage.isEmpty == true)
    }
}
