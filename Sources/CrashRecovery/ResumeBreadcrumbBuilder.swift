import Foundation

/// Pure builder for the "pick up where we left off" breadcrumb that cmux injects
/// into a restored agent *after* its native session resume (`claude --resume`,
/// `codex` resume) has reloaded the agent's own context.
///
/// The breadcrumb's job is human-language re-entry, anchored on the persisted
/// workspace name — the one piece of memory that survives a crash when neither
/// the user nor cmux remembers what a window was for. The agent's transcript
/// holds the real detail; this prompt just points it at the right thread and
/// says "continue".
///
/// Everything here is pure and side-effect free so it is trivially testable and
/// carries no UI/process coupling. The text is delivered as terminal *startup
/// input*, so it is sanitized to a single line (embedded newlines would submit
/// the prompt prematurely).
enum ResumeBreadcrumbBuilder {

    /// Why a restored workspace cannot be auto-resumed. Surfaced to the user
    /// (offer modal / disabled menu tooltip) — never thrown.
    enum SkipReason: Hashable, Sendable {
        /// No agent session id was persisted, so there is nothing to resume.
        case noSessionId
        /// A session id exists but the restore could not prove it is live/valid.
        case unprovenSession
        /// The agent is outside the v1 supported set (Claude Code, Codex).
        case unsupportedAgent(RestorableAgentKind)

        /// Short, user-facing reason. Localized at the call site for display;
        /// this raw form is stable for logging and tests.
        var debugDescription: String {
            switch self {
            case .noSessionId: return "no saved agent session to resume"
            case .unprovenSession: return "saved session could not be verified"
            case .unsupportedAgent(let kind): return "resume not supported for \(kind.displayName)"
            }
        }
    }

    /// Agents whose native-resume + breadcrumb flow v1 supports.
    static func isSupported(_ kind: RestorableAgentKind) -> Bool {
        switch kind {
        case .claude, .codex: return true
        default: return false
        }
    }

    /// Builds the breadcrumb prompt for a restored workspace.
    ///
    /// - Parameters:
    ///   - workspaceName: the workspace's persisted display name (its auto- or
    ///     user-set `customTitle`). May be empty/blank — a generic fallback is
    ///     used so the prompt never contains dangling quotes.
    ///   - agent: the agent kind (reserved for future per-agent phrasing; v1
    ///     uses one template because the agent's own resume already reloaded
    ///     context).
    static func breadcrumb(workspaceName: String, agent: RestorableAgentKind) -> String {
        let name = sanitizedName(workspaceName)
        let lead: String
        if let name {
            lead = "We were working on \"\(name)\" in this window last session."
        } else {
            lead = "We were working in this window last session."
        }
        return "\(lead) Please review your context and notes, then pick up where we left off."
    }

    /// Collapses a raw workspace name into a safe single-line fragment suitable
    /// for injection as terminal startup input. Returns `nil` when nothing
    /// usable remains (so the caller uses the no-name template).
    ///
    /// - Strips control characters and newlines (which would submit the prompt
    ///   early or corrupt the input).
    /// - Removes embedded double quotes so they cannot break the `"…"` wrapper.
    /// - Collapses runs of whitespace and trims.
    /// - Caps length to keep the injected line bounded.
    static func sanitizedName(_ raw: String, maxLength: Int = 120) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "\"" {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > maxLength {
            let clipped = String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
            return clipped.isEmpty ? nil : clipped + "\u{2026}"
        }
        return collapsed
    }
}
