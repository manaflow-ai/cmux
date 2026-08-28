import Testing
@testable import CmuxAgentJournal

@Suite("Semantic event mapper")
struct AgentSemanticEventMapperTests {
    private let mapper = AgentSemanticEventMapper()

    @Test(arguments: [
        // Generic arms shared by claude/codex/gemini/cursor/grok/kiro/kimi…
        ("claude", "SessionStart", nil, AgentJournalEventKind.sessionStarted),
        ("claude", "UserPromptSubmit", nil, .turnStarted),
        ("claude", "Stop", nil, .turnCompleted),
        ("claude", "SessionEnd", nil, .sessionEnded),
        ("claude", "PermissionRequest", nil, .approvalRequested),
        ("claude", "StopFailure", nil, .errorReported),
        ("claude", "SubagentStart", nil, .childSpawned),
        ("claude", "SubagentStop", nil, .childCompleted),
        ("claude", "Notification", nil, .stateChanged),
        ("codex", "SessionStart", nil, .sessionStarted),
        ("codex", "Stop", nil, .turnCompleted),
        ("cursor", "beforeSubmitPrompt", nil, .turnStarted),
        ("cursor", "afterAgentResponse", nil, .turnCompleted),
        ("gemini", "BeforeAgent", nil, .turnStarted),
        ("gemini", "AfterAgent", nil, .turnCompleted),
        ("kimi", "StopFailure", nil, .errorReported),
        ("kiro", "agentSpawn", nil, .childSpawned),
        ("rovodev", "on_complete", nil, .turnCompleted),
        ("rovodev", "on_error", nil, .errorReported),
        ("rovodev", "on_tool_permission", nil, .approvalRequested),
        ("hermes-agent", "pre_llm_call", nil, .turnStarted),
        ("hermes-agent", "post_llm_call", nil, .turnCompleted),
        ("hermes-agent", "pre_approval_request", nil, .approvalRequested),
        ("hermes-agent", "on_session_reset", nil, .sessionStarted),
        ("hermes-agent", "on_session_finalize", nil, .sessionEnded),
        // Source-specific arms.
        ("antigravity", "SessionEnd", nil, .turnCompleted),
        ("antigravity", "turn-completion", nil, .turnCompleted),
        ("hermes-agent", "on_session_end", nil, .turnCompleted),
        ("opencode", "session.created", nil, .sessionStarted),
        ("opencode", "session.idle", nil, .turnCompleted),
        ("opencode", "session.deleted", nil, .sessionEnded),
        ("copilot", "Notification", nil, .turnCompleted),
        ("codebuddy", "Notification", nil, .turnCompleted),
        ("factory", "Notification", nil, .turnCompleted),
        ("grok", "Notification", nil, .stateChanged),
        // Blocking tools outrank event names.
        ("claude", "PreToolUse", "AskUserQuestion", .questionRequested),
        ("claude", "PreToolUse", "ExitPlanMode", .planReviewRequested),
        ("codex", "PreToolUse", "exit_plan_mode", .planReviewRequested),
        // questionAsked shortcut.
        ("pi", "questionAsked", nil, .questionRequested),
        // Unknown events observe, never fabricate needs-input.
        ("claude", "SomethingBrandNew", nil, .stateChanged),
        ("qoder", "", nil, .stateChanged),
    ] as [(String, String, String?, AgentJournalEventKind)])
    func mapsNativeEvents(entry: (String, String, String?, AgentJournalEventKind)) {
        let (source, native, tool, expected) = entry
        #expect(mapper.kind(source: source, nativeEvent: native, toolName: tool) == expected)
    }

    @Test func normalizationCollapsesNamingConventions() {
        for variant in ["SubagentStop", "subagent_stop", "subagent-stop", "SUBAGENT.STOP"] {
            #expect(mapper.kind(source: "claude", nativeEvent: variant, toolName: nil) == .childCompleted)
        }
        #expect(AgentSemanticEventMapper.semanticKey("On-Session_End") == "onsessionend")
        #expect(AgentSemanticEventMapper.semanticKey("turn-completion") == "turncompletion")
    }
}
