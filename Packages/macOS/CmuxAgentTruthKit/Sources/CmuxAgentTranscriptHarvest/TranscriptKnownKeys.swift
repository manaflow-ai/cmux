import Foundation

struct TranscriptKnownKeys {
    static let claudeTopLevel: Set<String> = [
        "cwd",
        "isMeta",
        "isSidechain",
        "leafUuid",
        "message",
        "parentUuid",
        "requestId",
        "sessionId",
        "summary",
        "timestamp",
        "toolUseID",
        "toolUseResult",
        "type",
        "userType",
        "uuid",
        "version",
    ]

    static let codexFunctionPayloadTypes: Set<String> = [
        "custom_tool_call",
        "function_call",
        "web_search_call",
    ]
}
