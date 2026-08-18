#if os(iOS)
import CmuxMobileShellModel
import Foundation

/// One Feed row prepared outside `body`: the immutable item plus every
/// derived string the row renders, so row bodies do no string work during
/// scroll (the same discipline as `NotificationFeedRowModel`).
struct AgentFeedRowModel: Identifiable, Equatable, Sendable {
    let item: MobileAgentFeedItem
    let presentation: AgentFeedRowPresentation

    init(item: MobileAgentFeedItem) {
        self.item = item
        presentation = AgentFeedRowPresentation(item: item)
    }

    var id: MobileAgentFeedItemID { item.id }

    /// `presentation` is a pure derivation of `item`.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
    }
}

/// The precomputed strings of one X-style Feed row: author line, headline,
/// inline output, tool line, and the resolved-decision label.
struct AgentFeedRowPresentation: Equatable, Sendable {
    /// The agent's display name ("Claude", "Codex", ...).
    let authorName: String
    /// The `agent:<source>` icon value consumed by ``TaskTemplateIcon``.
    let authorIconValue: String
    /// What happened, in words ("asked to use Bash", "proposed a plan").
    let headline: String
    /// The user's ask the row responds to, quoted above the output.
    let quotedUserMessage: String?
    /// The agent's own words rendered inline (preamble, plan, prompt, text).
    let outputText: String?
    /// A compact monospaced tool line (tool name + one-line input).
    let toolLine: String?
    /// Provenance: workspace and surface titles when the Mac resolved them.
    let provenance: String?
    /// The decision label of a resolved or expired row.
    let resolutionLabel: String?
    /// Whether the plan text is long enough to collapse behind "Show more".
    let outputIsExpandable: Bool

    init(item: MobileAgentFeedItem) {
        authorName = AgentFeedRowPresentation.authorName(forSource: item.source)
        authorIconValue = "agent:\(item.source)"
        headline = AgentFeedRowPresentation.headline(for: item)
        let output = AgentFeedRowPresentation.outputText(for: item)
        outputText = output
        outputIsExpandable = (output?.count ?? 0) > 600
        quotedUserMessage = AgentFeedRowPresentation.quotedUserMessage(for: item)
        toolLine = AgentFeedRowPresentation.toolLine(for: item)
        provenance = AgentFeedRowPresentation.provenance(for: item)
        resolutionLabel = AgentFeedRowPresentation.resolutionLabel(for: item)
    }

    private static func authorName(forSource source: String) -> String {
        switch source.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        default:
            guard let first = source.first else { return source }
            return first.uppercased() + source.dropFirst()
        }
    }

    private static func headline(for item: MobileAgentFeedItem) -> String {
        switch item.kind {
        case .permissionRequest:
            let tool = item.toolName ?? String(
                localized: "mobile.agentFeed.headline.unknownTool",
                defaultValue: "a tool",
                bundle: .module
            )
            return String(
                localized: "mobile.agentFeed.headline.permission",
                defaultValue: "asked to use \(tool)",
                bundle: .module
            )
        case .exitPlan:
            return String(
                localized: "mobile.agentFeed.headline.exitPlan",
                defaultValue: "proposed a plan",
                bundle: .module
            )
        case .question:
            return String(
                localized: "mobile.agentFeed.headline.question",
                defaultValue: "asked a question",
                bundle: .module
            )
        case .stop:
            return String(
                localized: "mobile.agentFeed.headline.stop",
                defaultValue: "finished a turn",
                bundle: .module
            )
        case .userPrompt:
            return String(
                localized: "mobile.agentFeed.headline.userPrompt",
                defaultValue: "received your prompt",
                bundle: .module
            )
        case .assistantMessage:
            return String(
                localized: "mobile.agentFeed.headline.assistantMessage",
                defaultValue: "said",
                bundle: .module
            )
        case .toolUse:
            let tool = item.toolName ?? String(
                localized: "mobile.agentFeed.headline.unknownTool",
                defaultValue: "a tool",
                bundle: .module
            )
            return String(
                localized: "mobile.agentFeed.headline.toolUse",
                defaultValue: "ran \(tool)",
                bundle: .module
            )
        case .toolResult:
            let tool = item.toolName ?? String(
                localized: "mobile.agentFeed.headline.unknownTool",
                defaultValue: "a tool",
                bundle: .module
            )
            return item.toolResultIsError
                ? String(
                    localized: "mobile.agentFeed.headline.toolFailed",
                    defaultValue: "\(tool) failed",
                    bundle: .module
                )
                : String(
                    localized: "mobile.agentFeed.headline.toolFinished",
                    defaultValue: "finished \(tool)",
                    bundle: .module
                )
        case .todos:
            return String(
                localized: "mobile.agentFeed.headline.todos",
                defaultValue: "updated the plan checklist",
                bundle: .module
            )
        case .unsupported:
            return String(
                localized: "mobile.agentFeed.headline.unsupported",
                defaultValue: "sent an update",
                bundle: .module
            )
        }
    }

    private static func outputText(for item: MobileAgentFeedItem) -> String? {
        switch item.kind {
        case .permissionRequest:
            return normalized(item.context?.assistantPreamble)
        case .exitPlan:
            // Newer Macs send parsed plan text; older ones send the agent's
            // raw ExitPlanMode JSON envelope. Never render wire JSON.
            return planText(from: item.plan) ?? normalized(item.planSummary)
        case .question:
            let question = item.questions.first
            let header = normalized(question?.header)
            let prompt = normalized(question?.prompt)
            switch (header, prompt) {
            case let (header?, prompt?):
                return "\(header)\n\(prompt)"
            case let (header?, nil):
                return header
            case let (nil, prompt?):
                return prompt
            case (nil, nil):
                return normalized(item.context?.assistantPreamble)
            }
        case .stop:
            return normalized(item.stopReason) ?? normalized(item.context?.assistantPreamble)
        case .userPrompt, .assistantMessage:
            return normalized(item.text)
        case .toolUse:
            return normalized(item.context?.toolSummary)
        case .toolResult:
            return nil
        case .todos, .unsupported:
            return nil
        }
    }

    private static func quotedUserMessage(for item: MobileAgentFeedItem) -> String? {
        switch item.kind {
        case .permissionRequest, .exitPlan, .question, .stop:
            return normalized(item.context?.lastUserMessage)
        case .toolUse, .toolResult, .userPrompt, .assistantMessage, .todos, .unsupported:
            return nil
        }
    }

    private static func toolLine(for item: MobileAgentFeedItem) -> String? {
        switch item.kind {
        case .permissionRequest, .toolUse:
            return humanizedToolText(item.toolInput)
        case .toolResult:
            return humanizedToolText(item.toolResult)
        case .exitPlan, .question, .stop, .userPrompt, .assistantMessage, .todos, .unsupported:
            return nil
        }
    }

    /// Renders a tool payload as human text, never as wire JSON: the well-known
    /// single fields (`command`, `file_path`, prompt-ish keys) come through
    /// verbatim, other objects flatten to `key: value` pairs, and anything
    /// that would still read as JSON is dropped instead of shown raw.
    private static func humanizedToolText(_ raw: String?) -> String? {
        guard let normalized = normalized(raw) else { return nil }
        var value: Any = normalized
        // Tolerate one level of double-encoding ("\"{\\\"k\\\":1}\"").
        for _ in 0..<2 {
            guard let string = value as? String,
                  let data = string.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(
                      with: data,
                      options: [.fragmentsAllowed]
                  ) else { break }
            value = parsed
        }

        if let string = value as? String {
            return looksLikeJSON(string) ? nil : compactedSingleLine(string)
        }
        if let dict = value as? [String: Any] {
            for key in ["command", "file_path", "path", "prompt", "text", "message", "url", "pattern"] {
                if let field = dict[key] as? String, let line = compactedSingleLine(field) {
                    return line
                }
            }
            let pairs = dict
                .compactMap { key, value -> (String, String)? in
                    switch value {
                    case let string as String:
                        return normalized(string).map { (key, $0) }
                    case let number as NSNumber:
                        return (key, number.stringValue)
                    default:
                        return nil
                    }
                }
                .sorted { $0.0 < $1.0 }
                .prefix(3)
                .map { "\($0.0): \($0.1)" }
            guard !pairs.isEmpty else { return nil }
            return compactedSingleLine(pairs.joined(separator: " · "))
        }
        return nil
    }

    /// Parses a plan payload: parsed plan text passes through; an ExitPlanMode
    /// JSON envelope from an older Mac yields its `plan` field.
    private static func planText(from raw: String?) -> String? {
        guard let normalized = normalized(raw) else { return nil }
        guard looksLikeJSON(normalized) else { return normalized }
        guard let data = normalized.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        if let dict = parsed as? [String: Any] {
            for key in ["plan", "planText", "text"] {
                if let plan = dict[key] as? String {
                    return Self.normalized(plan)
                }
            }
            return nil
        }
        if let string = parsed as? String {
            return Self.normalized(string)
        }
        return nil
    }

    private static func looksLikeJSON(_ value: String) -> Bool {
        guard let first = value.first else { return false }
        return first == "{" || first == "[" || value.hasPrefix("\"{") || value.hasPrefix("\"[")
    }

    private static func provenance(for item: MobileAgentFeedItem) -> String? {
        var parts: [String] = []
        if let workspace = normalized(item.workspaceTitle) {
            parts.append(workspace)
        }
        if let surface = normalized(item.surfaceTitle) {
            parts.append(surface)
        }
        if parts.isEmpty, let cwd = normalized(item.cwd) {
            parts.append((cwd as NSString).lastPathComponent)
        }
        parts.append(item.macDisplayName)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func resolutionLabel(for item: MobileAgentFeedItem) -> String? {
        switch item.status {
        case .pending, .telemetry:
            return nil
        case .expired:
            return String(
                localized: "mobile.agentFeed.resolution.expired",
                defaultValue: "Expired unanswered",
                bundle: .module
            )
        case .resolved(let decision):
            switch decision.kind {
            case "permission":
                switch decision.mode {
                case "once":
                    return String(
                        localized: "mobile.agentFeed.resolution.allowedOnce",
                        defaultValue: "Allowed once",
                        bundle: .module
                    )
                case "always":
                    return String(
                        localized: "mobile.agentFeed.resolution.allowedAlways",
                        defaultValue: "Always allowed",
                        bundle: .module
                    )
                case "all":
                    return String(
                        localized: "mobile.agentFeed.resolution.allowedAll",
                        defaultValue: "Allowed all",
                        bundle: .module
                    )
                case "bypass":
                    return String(
                        localized: "mobile.agentFeed.resolution.bypassed",
                        defaultValue: "Permissions bypassed",
                        bundle: .module
                    )
                case "deny":
                    return String(
                        localized: "mobile.agentFeed.resolution.denied",
                        defaultValue: "Denied",
                        bundle: .module
                    )
                default:
                    return String(
                        localized: "mobile.agentFeed.resolution.resolved",
                        defaultValue: "Resolved",
                        bundle: .module
                    )
                }
            case "exit_plan":
                if decision.mode == "deny" {
                    return String(
                        localized: "mobile.agentFeed.resolution.denied",
                        defaultValue: "Denied",
                        bundle: .module
                    )
                }
                if let feedback = normalized(decision.feedback) {
                    return String(
                        localized: "mobile.agentFeed.resolution.revisionRequested",
                        defaultValue: "Revision requested: \(feedback)",
                        bundle: .module
                    )
                }
                return String(
                    localized: "mobile.agentFeed.resolution.planApproved",
                    defaultValue: "Plan approved",
                    bundle: .module
                )
            case "question":
                let labels = resolvedSelectionLabels(item: item, decision: decision)
                if labels.isEmpty {
                    return String(
                        localized: "mobile.agentFeed.resolution.answered",
                        defaultValue: "Answered",
                        bundle: .module
                    )
                }
                let joined = labels.joined(separator: ", ")
                return String(
                    localized: "mobile.agentFeed.resolution.answeredWith",
                    defaultValue: "Answered: \(joined)",
                    bundle: .module
                )
            default:
                return String(
                    localized: "mobile.agentFeed.resolution.resolved",
                    defaultValue: "Resolved",
                    bundle: .module
                )
            }
        }
    }

    /// Question decisions carry option IDS (free text stays raw). Map ids
    /// back to their option labels for the resolution line.
    private static func resolvedSelectionLabels(
        item: MobileAgentFeedItem,
        decision: MobileAgentFeedDecision
    ) -> [String] {
        var labelsByOptionID: [String: String] = [:]
        for question in item.questions {
            for option in question.options {
                labelsByOptionID[option.id] = option.label
            }
        }
        return decision.selections.map { labelsByOptionID[$0] ?? $0 }
    }

    private static func compactedSingleLine(_ value: String?) -> String? {
        guard let normalized = normalized(value) else { return nil }
        let joined = normalized
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        if joined.count > 200 {
            return String(joined.prefix(200)) + "…"
        }
        return joined
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Compact X-style trailing time label ("now", "5m", "3h", "2d", "Jun 4"),
/// derived from the deterministic ``MobileRelativeActivity`` buckets.
func agentFeedCompactTimeLabel(for date: Date, now: Date) -> String {
    switch MobileRelativeActivity.bucket(for: date, now: now) {
    case .none:
        return ""
    case .now:
        return String(
            localized: "mobile.agentFeed.time.now",
            defaultValue: "now",
            bundle: .module
        )
    case .minutes(let minutes):
        return String(
            localized: "mobile.agentFeed.time.minutes",
            defaultValue: "\(minutes)m",
            bundle: .module
        )
    case .hours(let hours):
        return String(
            localized: "mobile.agentFeed.time.hours",
            defaultValue: "\(hours)h",
            bundle: .module
        )
    case .days(let days):
        return String(
            localized: "mobile.agentFeed.time.days",
            defaultValue: "\(days)d",
            bundle: .module
        )
    case .monthDay:
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
#endif
