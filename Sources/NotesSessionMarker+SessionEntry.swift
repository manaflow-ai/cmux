import Foundation


// MARK: - Notes tree bridge

extension NotesSessionMarker {
    /// Resume commands splice the session id into shell input, and markers
    /// (`_session.json`) and the session-drag pasteboard are
    /// attacker-influenceable, so only plain token ids may cross this
    /// boundary into a `SessionEntry`.
    static func isSafeSessionId(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-", ":":
                return true
            default:
                return false
            }
        }
    }

    /// Minimal `SessionEntry` for resuming/dragging a Notes session folder.
    /// Markers persist only identity fields (agent, sessionId, cwd, title), so
    /// agent-specific resume details default to nil and the resume command
    /// falls back to its plain `<agent> resume <id>` form. Registered
    /// (cmux.json) agents re-resolve their registration so the command can be
    /// rebuilt; an unknown agent id or a session id that is not a plain token
    /// (shell-safe) yields nil.
    func makeSessionEntry() -> SessionEntry? {
        guard let sessionAgent = SessionAgent(rawValue: agent) else { return nil }
        let sessionId = self.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeSessionId(sessionId) else { return nil }
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let specifics: AgentSpecifics
        switch sessionAgent {
        case .claude:
            specifics = .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
        case .codex:
            specifics = .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
        case .grok:
            specifics = .grok(model: nil, permissionMode: nil, sandboxMode: nil, grokHome: nil)
        case .opencode:
            specifics = .opencode(providerModel: nil, agentName: nil)
        case .rovodev:
            specifics = .rovodev
        case .hermesAgent:
            specifics = .hermesAgent(source: nil, model: nil, hermesHome: nil)
        case .registered(let registered):
            let registry = CmuxVaultAgentRegistry.load(
                workingDirectory: trimmedCwd.isEmpty ? nil : trimmedCwd
            )
            guard let registration = registry.registration(id: registered.id) else { return nil }
            specifics = .registered(registration)
        }
        return SessionEntry(
            id: sessionId,
            agent: sessionAgent,
            sessionId: sessionId,
            title: title,
            cwd: trimmedCwd.isEmpty ? nil : trimmedCwd,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: modified ?? Date().timeIntervalSince1970),
            fileURL: nil,
            specifics: specifics
        )
    }
}
