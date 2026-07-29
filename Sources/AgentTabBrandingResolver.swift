import Foundation

/// Presentation policy for terminal tabs hosting a live coding-agent CLI.
///
/// Resolves which agent definition a panel's hook-driven runtime status keys
/// refer to, and how the tab title should read while that agent is attached.
/// Pure value logic so both decisions are unit-testable without a workspace.
struct AgentTabBrandingResolver {
    /// Maps a hook status key (the sidebar status-pill vocabulary from
    /// `AgentHibernationLifecycleStatusKeys.allowedStatusKeys`) to the
    /// definition id used by `CmuxTaskManagerCodingAgentDefinition.builtIns`.
    /// The two vocabularies agree except for `claude_code` → `claude`.
    func definitionID(forStatusKey statusKey: String) -> String {
        statusKey == "claude_code" ? "claude" : statusKey
    }

    /// The definition for a panel's current status keys, or `nil` when no key
    /// maps to a known agent. Iterates keys in sorted order so the result is
    /// deterministic on the rare panel that reports several agents at once.
    func definition(
        forStatusKeys statusKeys: some Collection<String>,
        in definitions: [CmuxTaskManagerCodingAgentDefinition]
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        for statusKey in statusKeys.sorted() {
            let definitionID = definitionID(forStatusKey: statusKey)
            if let definition = definitions.first(where: { $0.id == definitionID }) {
                return definition
            }
        }
        return nil
    }

    /// The tab title to show while `definition`'s CLI is attached to a panel.
    ///
    /// Launch-time branding only, mirroring what Claude Code's own titles do:
    ///
    /// - Until the CLI publishes a title of its own — the process title is
    ///   still whatever it was when the agent attached (usually the
    ///   shell-integration cwd title, which codex never replaces) — the tab
    ///   reads as the agent's display name.
    /// - Once the terminal title changes after attach, the CLI owns it and
    ///   the new title is kept verbatim (Claude Code's "✳ <task summary>"
    ///   titles keep updating the tab exactly as before).
    /// - The one exception is a bare binary-name title (grok sets a lowercase
    ///   "grok"), which is normalized to the canonical display name.
    ///
    /// - Parameters:
    ///   - processTitle: The panel's current process-reported title.
    ///   - titleAtAgentAttach: The process title recorded when the agent
    ///     attached to the panel; `nil` when none was recorded.
    ///   - definition: The attached agent's definition.
    func displayTitle(
        processTitle: String,
        titleAtAgentAttach: String?,
        for definition: CmuxTaskManagerCodingAgentDefinition
    ) -> String {
        let trimmed = processTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return definition.displayName }
        let attachTitle = titleAtAgentAttach?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == attachTitle {
            return definition.displayName
        }
        let normalized = trimmed.lowercased()
        if normalized == definition.displayName.lowercased()
            || normalized == definition.id.lowercased()
            || definition.directBasenames.contains(normalized) {
            return definition.displayName
        }
        return Self.strippingAgentStateGlyphPrefix(from: trimmed)
    }

    /// Leading state glyphs some agents prepend to their terminal titles
    /// (Claude Code cycles "✳"/"✶"/"✻"/"✽"). With the brand icon on the tab
    /// the glyph is redundant, so branded titles drop it.
    private static let agentStateGlyphPrefixes: Set<Character> = ["✳", "✶", "✻", "✽", "✢", "∗"]

    private static func strippingAgentStateGlyphPrefix(from title: String) -> String {
        var remainder = Substring(title)
        while let first = remainder.first, agentStateGlyphPrefixes.contains(first) {
            remainder = remainder.dropFirst().drop(while: { $0 == " " || $0 == "\u{FE0F}" })
        }
        let stripped = remainder.trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? title : stripped
    }
}
