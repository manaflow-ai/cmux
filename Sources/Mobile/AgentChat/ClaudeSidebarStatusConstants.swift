import Foundation

/// The exact sidebar status-row constants the cmux CLI emits for the Claude `"claude_code"` row
/// today (harvested verbatim from CLI/cmux.swift `setClaudeStatus` call sites, Task 1). The registry
/// bridge reuses these so the rewired dot is visually identical for the states the CLI already gets
/// right; only the missing reaper/clear behaviour changes.
///
/// Note: the CLI's `setClaudeStatus(value:icon:color:pid:)` helper has no `priority` parameter, so
/// every Claude row is emitted at the receiver's default priority (0) — including needs-input.
nonisolated enum ClaudeSidebarStatusConstants {
    /// The single status-row key the Claude pipeline owns. Mirrors the CLI-private
    /// `claudeCodeStatusKey = "claude_code"` (CLI/cmux.swift:2765 — not importable).
    static let statusKey = "claude_code"

    // .idle  (CLI/cmux.swift setClaudeStatus call ~:23185)
    static let idleValue = String(localized: "agentSession.web.status.idle", defaultValue: "Idle")
    static let idleIcon: String? = "pause.circle.fill"
    static let idleColor: String? = "#8E8E93"
    static let idlePriority = 0

    // .working  (CLI/cmux.swift setClaudeStatus calls ~:23088, ~:23308, ~:23672)
    static let workingValue = String(localized: "agent.generic.status.running", defaultValue: "Running")
    static let workingIcon: String? = "bolt.fill"
    static let workingColor: String? = "#4C8DFF"
    static let workingPriority = 0

    // .needsInput  (CLI/cmux.swift setClaudeStatus call ~:23429) — no --priority emitted (default 0)
    static let needsInputValue = String(localized: "feed.status.needsInput", defaultValue: "Needs input")
    static let needsInputIcon: String? = "bell.fill"
    static let needsInputColor: String? = "#4C8DFF"
    static let needsInputPriority = 0
}
