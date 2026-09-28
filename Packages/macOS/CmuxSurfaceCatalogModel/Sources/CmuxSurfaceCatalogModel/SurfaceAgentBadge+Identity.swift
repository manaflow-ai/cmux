import Foundation

extension SurfaceAgentBadge {
    /// The adapter identity (`claude`, `codex`, ...), never report provenance
    /// (`hook`, `socket`, `detected`, `plugin`). Claude's aliases read as `claude`,
    /// the name local agent sessions use. Nil when only provenance is known.
    public var agentIdentity: String? {
        let provenance: Set<String> = ["hook", "socket", "detected", "plugin", "unknown"]
        let identity = [agent, source]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty && !provenance.contains($0) }
        switch identity {
        case "claude", "claude-code", "claude_code": return "claude"
        case let identity?:
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            let bounded = String(identity.unicodeScalars.filter(allowed.contains).prefix(64))
            return bounded.isEmpty ? nil : bounded
        case nil: return nil
        }
    }

    /// The daemon state in the local agent-session vocabulary: cmux-tui
    /// `blocked` is `needs_input` and `done` is `ended`. Other states pass through.
    public var sessionState: String {
        switch state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "blocked", "needs_input": return "needs_input"
        case "done", "ended": return "ended"
        case "working": return "working"
        case "idle": return "idle"
        case "unknown", "": return "unknown"
        default: return state
        }
    }
}
