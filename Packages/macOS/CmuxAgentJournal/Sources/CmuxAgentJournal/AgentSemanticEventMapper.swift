/// Maps an adapter's native hook event to a semantic journal kind.
///
/// This is a Swift port of the cmux-tui journal's mapping table
/// (`agent_hooks.rs` `semantic_kind`): matching runs over a normalized key
/// (lowercased, all non-alphanumeric bytes stripped) so `SubagentStop`,
/// `subagent_stop`, and `on-subagent-stop` all collapse to the same arm, and
/// only a handful of adapters carry source-specific special cases. Everything
/// that fails to map lands on ``AgentJournalEventKind/stateChanged`` — never
/// on a fabricated needs-input state.
///
/// ```swift
/// let mapper = AgentSemanticEventMapper()
/// mapper.kind(source: "claude", nativeEvent: "Stop", toolName: nil)
/// // .turnCompleted
/// mapper.kind(source: "claude", nativeEvent: "PreToolUse", toolName: "ExitPlanMode")
/// // .planReviewRequested
/// ```
public struct AgentSemanticEventMapper: Sendable {
    /// Creates a mapper.
    public init() {}

    /// Resolves the semantic kind for a native hook event.
    ///
    /// - Parameters:
    ///   - source: Stable agent slug of the adapter (e.g. `claude`, `grok`).
    ///   - nativeEvent: The adapter's native hook event name.
    ///   - toolName: The tool named by the event, when the adapter provides
    ///     one; blocking tools map ahead of the event-name table.
    /// - Returns: The semantic kind, ``AgentJournalEventKind/stateChanged``
    ///   when nothing stronger matches.
    public func kind(
        source: String,
        nativeEvent: String,
        toolName: String? = nil
    ) -> AgentJournalEventKind {
        let event = Self.semanticKey(nativeEvent)
        if let toolName {
            switch Self.semanticKey(toolName) {
            case "askuserquestion":
                return .questionRequested
            case "exitplanmode":
                return .planReviewRequested
            default:
                break
            }
        }
        if event == "questionasked" {
            return .questionRequested
        }
        // Source-specific arms first (mirrors the Rust table's ordering).
        switch (source, event) {
        case ("antigravity", "sessionend"), ("antigravity", "onsessionend"),
             ("hermes-agent", "sessionend"), ("hermes-agent", "onsessionend"):
            // These providers use their session-end callback as a per-turn
            // boundary and expose a distinct finalization event where available.
            return .turnCompleted
        case ("opencode", "sessioncreated"):
            return .sessionStarted
        case ("opencode", "sessionidle"):
            return .turnCompleted
        case ("opencode", "sessiondeleted"):
            return .sessionEnded
        case ("copilot", "notification"), ("codebuddy", "notification"), ("factory", "notification"):
            // These Claude-compatible runtimes use Notification as their only
            // reliable completed-turn callback.
            return .turnCompleted
        default:
            break
        }
        if Self.childSpawnEvents.contains(event) { return .childSpawned }
        if Self.childCompletionEvents.contains(event) { return .childCompleted }
        if event == "subagentfailed" || event == "childfailed" { return .childFailed }
        if Self.sessionStartEvents.contains(event) { return .sessionStarted }
        if Self.turnStartEvents.contains(event) { return .turnStarted }
        if Self.turnCompletionEvents.contains(event) { return .turnCompleted }
        if Self.approvalEvents.contains(event) { return .approvalRequested }
        if Self.errorEvents.contains(event) { return .errorReported }
        if Self.sessionEndEvents.contains(event) { return .sessionEnded }
        return .stateChanged
    }

    /// Normalizes a native event or tool name for table matching: lowercases
    /// and strips every non-alphanumeric character, so naming-convention
    /// variants collapse to one key.
    ///
    /// - Parameter raw: The raw native name.
    /// - Returns: The normalized key.
    public static func semanticKey(_ raw: String) -> String {
        String(raw.lowercased().unicodeScalars.filter { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
        })
    }

    private static let childSpawnEvents: Set<String> = [
        "subagentstart", "subagentstarted", "subagentspawned",
        "agentspawn", "agentspawned",
        "childstart", "childstarted", "childspawned",
    ]

    private static let childCompletionEvents: Set<String> = [
        "subagentstop", "subagentended", "subagentcompleted",
        "childstop", "childended", "childcompleted",
    ]

    private static let sessionStartEvents: Set<String> = [
        "sessionstart", "onsessionstart", "onsessionreset",
    ]

    private static let turnStartEvents: Set<String> = [
        "userpromptsubmit", "beforesubmitprompt", "beforeagent", "prellmcall",
        "preinvocation", "agentstart", "turnstart", "beforeagentstart",
    ]

    private static let turnCompletionEvents: Set<String> = [
        "stop", "afteragent", "afteragentresponse", "postllmcall", "oncomplete",
        "turncompletion", "agentend", "taskcompleted", "turnend", "agentsettled",
    ]

    private static let approvalEvents: Set<String> = [
        "permissionrequest", "permissionasked", "preapprovalrequest", "ontoolpermission",
    ]

    private static let errorEvents: Set<String> = [
        "stopfailure", "onerror", "error", "posttoolusefailure",
    ]

    private static let sessionEndEvents: Set<String> = [
        "sessionend", "onsessionend", "onsessionfinalize", "sessionshutdown",
    ]
}
