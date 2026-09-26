import Foundation

/// JSONL fixture builders mirroring real Claude Code transcripts and Codex
/// rollouts (field names and nesting as written by the CLIs; values made up).
struct AgentUsageFixtures {
    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func claudeAssistant(
        id: String?,
        model: String = "claude-opus-4-8",
        input: Int,
        cacheCreation: Int = 0,
        cacheCreation1h: Int? = nil,
        cacheRead: Int = 0,
        output: Int,
        isSidechain: Bool = false
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": input,
            "cache_creation_input_tokens": cacheCreation,
            "cache_read_input_tokens": cacheRead,
            "output_tokens": output,
            "service_tier": "standard",
        ]
        if let cacheCreation1h {
            usage["cache_creation"] = [
                "ephemeral_5m_input_tokens": cacheCreation - cacheCreation1h,
                "ephemeral_1h_input_tokens": cacheCreation1h,
            ]
        }
        var message: [String: Any] = [
            "model": model,
            "role": "assistant",
            "type": "message",
            "content": [["type": "text", "text": "ok"]],
            "usage": usage,
        ]
        if let id { message["id"] = id }
        return json([
            "type": "assistant",
            "isSidechain": isSidechain,
            "sessionId": "s1",
            "message": message,
        ])
    }

    static func claudeUserToolResult() -> String {
        json([
            "type": "user",
            "isSidechain": false,
            "message": ["role": "user", "content": [["type": "tool_result", "content": "usage: none"]]],
        ])
    }

    static func codexTurnContext(model: String) -> String {
        json([
            "timestamp": "2026-09-25T23:56:00.889Z",
            "type": "turn_context",
            "payload": ["turn_id": "t1", "cwd": "/tmp", "model": model, "effort": "low"],
        ])
    }

    static func codexTokenCount(
        totalInput: Int,
        totalCached: Int,
        totalOutput: Int,
        lastTotal: Int,
        window: Int
    ) -> String {
        json([
            "timestamp": "2026-09-25T23:56:04.885Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": totalInput,
                        "cached_input_tokens": totalCached,
                        "cache_write_input_tokens": 0,
                        "output_tokens": totalOutput,
                        "reasoning_output_tokens": 0,
                        "total_tokens": totalInput + totalOutput,
                    ],
                    "last_token_usage": [
                        "input_tokens": lastTotal - 100,
                        "cached_input_tokens": 0,
                        "output_tokens": 100,
                        "total_tokens": lastTotal,
                    ],
                    "model_context_window": window,
                ],
                "rate_limits": ["primary": ["used_percent": 12.0, "window_minutes": 300]],
            ],
        ])
    }
}
