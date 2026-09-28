import AppKit
import CmuxSettings
import CmuxTerminalCore

/// Clickable agent key hints (`agentActions.keyHints`): a click on a hint an
/// agent printed, such as `ctrl+o to expand`, presses those keys.
extension TerminalPanel {
    /// Whether the key hints setting is on.
    static var agentKeyHintsEnabled: Bool {
        AgentActionsCatalogSection().keyHints.value(in: .standard)
    }

    /// The agent whose hints this pane can show: any journaled lifecycle for
    /// Claude Code, Codex, or OpenCode, running or not.
    var agentKeyHintAgent: AgentKeyHintDetector.Agent? {
        let states = containerAgentLifecycleStates
        guard !states.isEmpty else { return nil }
        if states["claude_code"] != nil { return .claudeCode }
        if states["codex"] != nil { return .codex }
        if states["opencode"] != nil { return .openCode }
        return nil
    }

    /// The hint covering `column` of a visible terminal line, when the
    /// setting is on and an agent runs in this pane.
    func agentKeyHint(
        inLine line: String,
        atColumn column: Int
    ) -> (hint: AgentKeyHint, agent: AgentKeyHintDetector.Agent)? {
        guard Self.agentKeyHintsEnabled, let agent = agentKeyHintAgent,
              let hint = AgentKeyHintDetector(agent: agent).hint(in: line, atColumn: column) else { return nil }
        return (hint, agent)
    }

    /// The keys a click on `hint` sends, after the user's Claude Code keybindings.
    func agentKeyHintKeys(for hint: AgentKeyHint, agent: AgentKeyHintDetector.Agent) -> [String] {
        let bindings = agent == .claudeCode ? ClaudeCodeKeybindingsFile.shared.current() : .empty
        return AgentKeyHintChordResolver(claudeKeybindings: bindings).keys(for: hint, agent: agent)
    }

    /// A click on an agent key hint, resolved before it is pressed.
    struct AgentKeyHintClick {
        var hint: AgentKeyHint
        var agent: AgentKeyHintDetector.Agent
    }

    /// The hint a left click on a terminal cell presses, when the click
    /// policy allows it: a plain click unless the agent captured the mouse,
    /// otherwise a Command-click.
    func agentKeyHintClick(
        line: String,
        column: Int,
        mouseCaptured: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> AgentKeyHintClick? {
        let flags = modifierFlags.intersection([.command, .shift, .option, .control])
        guard AgentKeyHintClickPolicy(
            mouseCaptured: mouseCaptured,
            commandHeld: flags.contains(.command),
            otherModifierHeld: !flags.subtracting(.command).isEmpty
        ).pressesHint,
            !isAgentHibernated,
            let match = agentKeyHint(inLine: line, atColumn: column) else { return nil }
        return AgentKeyHintClick(hint: match.hint, agent: match.agent)
    }

    /// Sends the keys for a clicked hint.
    ///
    /// - Returns: Whether any key was sent or queued.
    @discardableResult
    func pressAgentKeyHint(_ click: AgentKeyHintClick) -> Bool {
        var sent = false
        for key in agentKeyHintKeys(for: click.hint, agent: click.agent) {
            sent = surface.sendNamedKeyAvoidingTerminalBindings(key) || sent
        }
#if DEBUG
        cmuxDebugLog(
            "agentKeyHint.press panel=\(id.uuidString.prefix(5)) keys=\(click.hint.keys.joined(separator: ",")) " +
            "action=\(click.hint.action) sent=\(sent ? 1 : 0)"
        )
#endif
        return sent
    }
}
