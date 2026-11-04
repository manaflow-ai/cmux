import Foundation

/// Recorded agent CLI stdout, trimmed of fields the parsers ignore.
///
/// The Claude Code lines come from two live runs of Claude Code 2.1.300
/// (`.chief-work/harness-events.md` and a `can_use_tool` probe); the Codex
/// lines follow `codex app-server generate-json-schema` and acpmux's fake
/// app-server (`cmux-tui/crates/acpmux/tests/fake_codex_app_server.py`).
enum ChiefBrainFixtures {
    static let claudeSession = "2cffcbbc-4fc9-4406-a09f-60a692485c4f"
    static let claudePromptUUID = "4e61e433-2af0-4338-8b4a-7f23595a148c"

    /// "Reply with exactly: hi" on Haiku: init, echo, one text block, result.
    static let claudeTextTurn: [String] = [
        #"{"type":"system","subtype":"init","cwd":"/private/tmp/chief-probe","session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","tools":[],"mcp_servers":[],"model":"claude-haiku-5-5","permissionMode":"default","claude_code_version":"2.1.300","uuid":"30181481-d002-46fc-a572-9c3faffe1c7b"}"#,
        #"{"type":"system","subtype":"status","status":"requesting","session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","uuid":"e69651ba-e829-49b9-9ab0-238cd27cc430"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Reply with exactly: hi"}]},"session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","parent_tool_use_id":null,"uuid":"4e61e433-2af0-4338-8b4a-7f23595a148c","timestamp":"2026-10-15T10:55:13.000Z","isReplay":true}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-haiku-5-5","id":"msg_011Cg3uAthfZ2L4aMHyNqakA","type":"message","role":"assistant","content":[]}},"session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","parent_tool_use_id":null,"uuid":"f2c78464-b42d-45da-929a-01ad780469f8"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","parent_tool_use_id":null,"uuid":"cfb8f1dc-120b-4115-bee3-f24d88e9cbc4"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}},"session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","parent_tool_use_id":null,"uuid":"2ad3707d-317b-40ab-bff7-0658cd9b9dda"}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011Cg3uAthfZ2L4aMHyNqakA","type":"message","role":"assistant","content":[{"type":"text","text":"hi"}]},"parent_tool_use_id":null,"session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","uuid":"2a3cca93-50f0-4cd9-abd9-4f02fb802f71"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","parent_tool_use_id":null,"uuid":"dc3b4d0f-6903-4ede-9b02-a25c955cb7c3"}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}},"session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","parent_tool_use_id":null,"uuid":"acce6377-4871-437f-9671-5d7ac3d62dc2"}"#,
        #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","parent_tool_use_id":null,"uuid":"1eb1165e-3b5d-40e8-b9e7-f360a288530a"}"#,
        #"{"duration_api_ms":657,"stop_reason":"end_turn","session_id":"2cffcbbc-4fc9-4406-a09f-60a692485c4f","total_cost_usd":3.99e-05,"is_error":false,"num_turns":1,"subtype":"success","result":"hi","type":"result","duration_ms":684}"#,
    ]

    static let toolSession = "8451a3f9-a180-4137-9a4f-e51aba910f26"
    static let toolPromptUUID = "4132669e-be40-41a2-8105-a2d186733a5c"

    /// A Bash call that asks permission, runs, then a text reply.
    static let claudeToolTurn: [String] = [
        #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[]}}}"#,
        #"{"type":"command_lifecycle","command_uuid":"4132669e-be40-41a2-8105-a2d186733a5c","state":"started","uuid":"9c5387f5-c38a-48de-b6af-c4c12b0d3cb5","session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26"}"#,
        #"{"type":"system","subtype":"init","session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","model":"claude-haiku-5-5"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Use the Bash tool"}]},"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","parent_tool_use_id":null,"uuid":"4132669e-be40-41a2-8105-a2d186733a5c","isReplay":true}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01X8nuDECCbcBCpyE7qgG1kw","name":"Bash","input":{},"caller":{"type":"direct"}}},"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011Cg3ur7wjkW7nq5B58Ho7f","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01X8nuDECCbcBCpyE7qgG1kw","name":"Bash","input":{"command":"mkdir -p /tmp/chief-probe2/made","description":"Make dir"},"caller":{"type":"direct"}}]},"parent_tool_use_id":null,"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","parent_tool_use_id":null}"#,
        #"{"type":"control_request","request_id":"4efd7959-8a24-4a8a-877d-fbf0304f7e7e","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"mkdir -p /tmp/chief-probe2/made","description":"Make dir"},"description":"Make dir","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"mkdir -p /tmp/chief-probe2/made"}],"behavior":"allow","destination":"localSettings"}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01X8nuDECCbcBCpyE7qgG1kw","type":"tool_result","content":"(Bash completed with no output)","is_error":false}]},"parent_tool_use_id":null,"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","uuid":"664f32ef-7c5a-4e25-a66d-cfb50cfe52cb"}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_011Cg3urD7HWabr5BrLoyQVo","content":[]}},"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}},"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"id":"msg_011Cg3urD7HWabr5BrLoyQVo","type":"message","role":"assistant","content":[{"type":"text","text":"done"}]},"parent_tool_use_id":null,"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","parent_tool_use_id":null}"#,
        #"{"duration_api_ms":2397,"stop_reason":"end_turn","session_id":"8451a3f9-a180-4137-9a4f-e51aba910f26","is_error":false,"num_turns":2,"subtype":"success","result":"done","type":"result"}"#,
    ]

    /// One Codex turn: a command, then a streamed reply.
    static let codexTurn: [String] = [
        #"{"id":3,"result":{"turn":{"id":"turn-1","status":"inProgress","items":[]}}}"#,
        #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"inProgress","items":[]}}}"#,
        #"{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"commandExecution","id":"call-1","command":"/bin/zsh -lc 'cmux list-workspaces'","commandActions":[],"cwd":"/tmp","status":"inProgress"}}}"#,
        #"{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"call-1","startedAtMs":1,"command":"/bin/zsh -lc 'cmux list-workspaces'"}}"#,
        #"{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"call-1","delta":"ws-1\n"}}"#,
        #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"commandExecution","id":"call-1","command":"/bin/zsh -lc 'cmux list-workspaces'","commandActions":[],"cwd":"/tmp","status":"completed","exitCode":0,"aggregatedOutput":"ws-1\nws-2\n"}}}"#,
        #"{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":2,"item":{"type":"agentMessage","id":"msg-1","text":""}}}"#,
        #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"msg-1","delta":"Two "}}"#,
        #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"msg-1","delta":"workspaces."}}"#,
        #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"msg-1","text":"Two workspaces."}}}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-1","turnId":"turn-1"}}"#,
        #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","items":[]}}}"#,
    ]
}
