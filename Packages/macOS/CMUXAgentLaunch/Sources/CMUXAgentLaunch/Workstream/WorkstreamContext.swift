import Foundation

/// Extra nearby conversation state attached to a feed event.
///
/// Hooks are often invoked for a tool call, so the tool payload alone is
/// missing the user's ask and the agent's short explanation before the tool.
/// This context travels with the item and is persisted with the feed row.
public struct WorkstreamContext: Codable, Sendable, Equatable {
    public let lastUserMessage: String?
    public let assistantPreamble: String?
    public let planSummary: String?
    public let allowedPrompts: [WorkstreamAllowedPrompt]
    public let toolSummary: String?
    /// Agent permission mode near this event. Claude records `plan`
    /// for plan-mode sessions, which lets the Feed distinguish planning
    /// interview questions from normal AskUserQuestion calls.
    public let permissionMode: String?

    public init(
        lastUserMessage: String? = nil,
        assistantPreamble: String? = nil,
        planSummary: String? = nil,
        allowedPrompts: [WorkstreamAllowedPrompt] = [],
        toolSummary: String? = nil,
        permissionMode: String? = nil
    ) {
        self.lastUserMessage = Self.cleaned(lastUserMessage)
        self.assistantPreamble = Self.cleaned(assistantPreamble)
        self.planSummary = Self.cleaned(planSummary)
        self.allowedPrompts = allowedPrompts.filter { !$0.prompt.isEmpty }
        self.toolSummary = Self.cleaned(toolSummary)
        self.permissionMode = Self.cleaned(permissionMode)
    }

    private enum CodingKeys: String, CodingKey {
        case lastUserMessage
        case assistantPreamble
        case planSummary
        case allowedPrompts
        case toolSummary
        case permissionMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lastUserMessage: try c.decodeIfPresent(String.self, forKey: .lastUserMessage),
            assistantPreamble: try c.decodeIfPresent(String.self, forKey: .assistantPreamble),
            planSummary: try c.decodeIfPresent(String.self, forKey: .planSummary),
            allowedPrompts: try c.decodeIfPresent(
                [WorkstreamAllowedPrompt].self,
                forKey: .allowedPrompts
            ) ?? [],
            toolSummary: try c.decodeIfPresent(String.self, forKey: .toolSummary),
            permissionMode: try c.decodeIfPresent(String.self, forKey: .permissionMode)
        )
    }

    public var isEmpty: Bool {
        lastUserMessage == nil
            && assistantPreamble == nil
            && planSummary == nil
            && allowedPrompts.isEmpty
            && toolSummary == nil
            && permissionMode == nil
    }

    /// Returns a context where non-empty values from `self` win and
    /// missing fields fall back to the previous context in the workstream.
    public func mergingMissing(from fallback: WorkstreamContext?) -> WorkstreamContext {
        guard let fallback else { return self }
        return WorkstreamContext(
            lastUserMessage: lastUserMessage ?? fallback.lastUserMessage,
            assistantPreamble: assistantPreamble ?? fallback.assistantPreamble,
            planSummary: planSummary ?? fallback.planSummary,
            allowedPrompts: allowedPrompts.isEmpty ? fallback.allowedPrompts : allowedPrompts,
            toolSummary: toolSummary ?? fallback.toolSummary,
            permissionMode: permissionMode ?? fallback.permissionMode
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct WorkstreamAllowedPrompt: Codable, Sendable, Equatable {
    public let tool: String
    public let prompt: String

    public init(tool: String, prompt: String) {
        self.tool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Parsed view of Claude's ExitPlanMode tool input.
///
/// Recent Claude versions pass a JSON object with `plan`,
/// `allowedPrompts`, and `planFilePath`. Older or unknown agents may pass
/// plain markdown. This parser keeps both forms displayable.
public struct WorkstreamExitPlanPreview: Sendable, Equatable {
    public let planText: String
    public let allowedPrompts: [WorkstreamAllowedPrompt]
    public let planFilePath: String?
    public let summary: String?

    public init(rawPlan: String) {
        let parsed = Self.parse(rawPlan)
        self.planText = parsed.planText
        self.allowedPrompts = parsed.allowedPrompts
        self.planFilePath = parsed.planFilePath
        self.summary = Self.summary(from: parsed.planText)
    }

    private static func parse(_ rawPlan: String) -> (
        planText: String,
        allowedPrompts: [WorkstreamAllowedPrompt],
        planFilePath: String?
    ) {
        guard let data = rawPlan.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              ) as? [String: Any]
        else {
            return (rawPlan, [], nil)
        }

        let planText = cleaned(dict["plan"] as? String) ?? rawPlan
        let planFilePath = cleaned(
            (dict["planFilePath"] as? String)
                ?? (dict["plan_file_path"] as? String)
        )
        return (
            planText,
            parseAllowedPrompts(dict["allowedPrompts"]),
            planFilePath
        )
    }

    private static func parseAllowedPrompts(_ raw: Any?) -> [WorkstreamAllowedPrompt] {
        guard let raw else { return [] }
        if let rows = raw as? [[String: Any]] {
            return rows.compactMap { row in
                let prompt = cleaned(row["prompt"] as? String)
                    ?? cleaned(row["description"] as? String)
                    ?? cleaned(row["text"] as? String)
                guard let prompt else { return nil }
                let tool = cleaned(row["tool"] as? String)
                    ?? cleaned(row["toolName"] as? String)
                    ?? ""
                return WorkstreamAllowedPrompt(tool: tool, prompt: prompt)
            }
        }
        if let rows = raw as? [Any] {
            return rows.compactMap { row in
                if let text = cleaned(row as? String) {
                    return WorkstreamAllowedPrompt(tool: "", prompt: text)
                }
                guard let dict = row as? [String: Any] else { return nil }
                let prompt = cleaned(dict["prompt"] as? String)
                    ?? cleaned(dict["description"] as? String)
                    ?? cleaned(dict["text"] as? String)
                guard let prompt else { return nil }
                let tool = cleaned(dict["tool"] as? String)
                    ?? cleaned(dict["toolName"] as? String)
                    ?? ""
                return WorkstreamAllowedPrompt(tool: tool, prompt: prompt)
            }
        }
        return []
    }

    private static func summary(from planText: String) -> String? {
        var firstHeading: String?
        for rawLine in planText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                if firstHeading == nil, !heading.isEmpty {
                    firstHeading = heading
                }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if let numbered = line.range(
                of: #"^\d+\.\s+(.+)$"#,
                options: .regularExpression
            ) {
                let text = String(line[numbered])
                if let dot = text.firstIndex(of: ".") {
                    return String(text[text.index(after: dot)...])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            return line
        }
        return firstHeading
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
