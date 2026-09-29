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

    /// The agent whose hints this pane can show: one with a journaled
    /// lifecycle for Claude Code, Codex, or OpenCode.
    var agentKeyHintAgent: AgentKeyHintDetector.Agent? {
        Self.agentKeyHintAgent(lifecycleStates: containerAgentLifecycleStates)
    }

    /// The agent to read hints for, given a pane's lifecycle states by agent
    /// key. An agent that is running or waiting for input wins over an idle
    /// one, and an idle one over one in an unknown state, so a stale
    /// lifecycle left by an agent that ran earlier in the pane does not
    /// decide how the live agent's hints read. Ties go to Claude Code, then
    /// Codex, then OpenCode.
    static func agentKeyHintAgent(
        lifecycleStates states: [String: AgentHibernationLifecycleState]
    ) -> AgentKeyHintDetector.Agent? {
        agentKeyHintAgentContext(lifecycleStates: states)?.agent
    }

    private static func agentKeyHintAgentContext(
        lifecycleStates states: [String: AgentHibernationLifecycleState]
    ) -> AgentKeyHintAgentContext? {
        let agents: [(key: String, agent: AgentKeyHintDetector.Agent)] = [
            ("claude_code", .claudeCode), ("codex", .codex), ("opencode", .openCode),
        ]
        func rank(_ state: AgentHibernationLifecycleState) -> Int {
            switch state {
            case .running, .needsInput: 0
            case .idle: 1
            case .unknown: 2
            }
        }
        var best: (context: AgentKeyHintAgentContext, rank: Int)?
        for (key, agent) in agents {
            guard let state = states[key] else { continue }
            let candidate = rank(state)
            if best.map({ candidate < $0.rank }) ?? true {
                best = (AgentKeyHintAgentContext(agent: agent, lifecycle: state), candidate)
            }
        }
        return best?.context
    }

    private var agentKeyHintAgentContext: AgentKeyHintAgentContext? {
        Self.agentKeyHintAgentContext(lifecycleStates: containerAgentLifecycleStates)
    }

    /// The hint covering `column` of a visible terminal row. The caller has
    /// checked the setting and the agent.
    ///
    /// - Parameter isLiveRow: Whether the row is in the agent's live region;
    ///   asked only for a hint whose keys need it.
    static func agentKeyHint(
        inLine line: String,
        atColumn column: Int,
        agent: AgentKeyHintDetector.Agent,
        isLiveRow: () -> Bool
    ) -> AgentKeyHint? {
        guard let hint = AgentKeyHintDetector(agent: agent).hint(in: line, atColumn: column, inLiveRegion: true),
              !hint.needsLiveRegion || isLiveRow() else { return nil }
        return hint
    }

    /// The keys a click on `hint` sends, after the user's Claude Code keybindings.
    ///
    /// - Parameter keybindingsMaxAge: Seconds an earlier check of the
    ///   keybindings file stays good for. A click passes `0`; hover passes
    ///   more so moving across cells does not stat the file each time.
    func agentKeyHintKeys(
        for hint: AgentKeyHint,
        agent: AgentKeyHintDetector.Agent,
        keybindingsMaxAge: TimeInterval = 0
    ) -> [String] {
        let bindings = agent == .claudeCode
            ? ClaudeCodeKeybindingsFile.shared.current(maxAge: keybindingsMaxAge)
            : .empty
        return AgentKeyHintChordResolver(claudeKeybindings: bindings).keys(for: hint, agent: agent)
    }

    /// The hint a left click on a terminal cell presses, when the setting is
    /// on, an agent runs in this pane, and the click policy allows it: a
    /// plain click unless the agent captured the mouse, otherwise a
    /// Command-click.
    ///
    /// - Parameter inLiveRegion: Whether the clicked row is in the agent's
    ///   live region (``AgentKeyHintLiveRegion``).
    func agentKeyHintClick(
        line: String,
        column: Int,
        inLiveRegion: Bool,
        mouseCaptured: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> AgentKeyHintClick? {
        let flags = modifierFlags.intersection([.command, .shift, .option, .control])
        let policy = AgentKeyHintClickPolicy(
            mouseCaptured: mouseCaptured,
            commandHeld: flags.contains(.command),
            otherModifierHeld: !flags.subtracting(.command).isEmpty
        )
        guard policy.pressesHint,
            Self.agentKeyHintsEnabled,
            !isAgentHibernated,
            let context = agentKeyHintAgentContext
        else { return nil }
        let hint = Self.agentKeyHint(
            inLine: line,
            atColumn: column,
            agent: context.agent,
            isLiveRow: { inLiveRegion }
        )
        let actionCommand: AgentActionCommand? = context.agent == .codex && inLiveRegion
            ? CodexActionCommandDetector().command(in: line, atColumn: column)
            : nil
        guard hint != nil || actionCommand != nil else { return nil }
        return AgentKeyHintClick(
            hint: hint ?? AgentKeyHint(keys: [], action: actionCommand!.command, columns: actionCommand!.columns),
            actionCommand: actionCommand,
            agent: context.agent,
            lifecycle: context.lifecycle,
            policy: policy
        )
    }

    /// Resolves a deferred click again immediately before it sends input.
    /// Every part of the authorization must still match the release: the
    /// hint, agent, lifecycle, and mouse-capture/modifier policy.
    func revalidatedAgentKeyHintClick(
        _ expected: AgentKeyHintClick,
        line: String,
        column: Int,
        inLiveRegion: Bool,
        mouseCaptured: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> AgentKeyHintClick? {
        guard let current = agentKeyHintClick(
            line: line,
            column: column,
            inLiveRegion: inLiveRegion,
            mouseCaptured: mouseCaptured,
            modifierFlags: modifierFlags
        ), current == expected else { return nil }
        return current
    }

    /// Sends the keys for a clicked hint.
    ///
    /// - Returns: Whether any key was sent or queued.
    @discardableResult
    func pressAgentKeyHint(_ click: AgentKeyHintClick) -> Bool {
        if let command = click.actionCommand {
            let sent = sendText(command.command + "\r")
#if DEBUG
            cmuxDebugLog("agentActionCommand.press panel=\(id.uuidString.prefix(5)) command=\(command.command) sent=\(sent ? 1 : 0)")
#endif
            return sent
        }
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
