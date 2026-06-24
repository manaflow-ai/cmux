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

    /// A *verified* restored binding's anchor for the forensic-recovery
    /// breadcrumb (U12/R15): the window's summary, its agent, and — when known —
    /// the exact on-disk transcript path that `ResumeFidelityGate` confirmed
    /// belongs to this window. Constructed only from a verified binding; the
    /// unverified path never reaches here (R15).
    struct VerifiedResumeAnchor: Equatable, Sendable {
        var workspaceName: String
        var agentKind: RestorableAgentKind
        /// The verified transcript path, when the binding carried one. Absent
        /// when only the session id verified (no recorded transcript path).
        var transcriptPath: String?

        init(workspaceName: String, agentKind: RestorableAgentKind, transcriptPath: String? = nil) {
            self.workspaceName = workspaceName
            self.agentKind = agentKind
            self.transcriptPath = transcriptPath
        }
    }

    /// Builds the breadcrumb for a *verified* restored binding, pointing the
    /// agent at its **specific** transcript when one is known (U12/KTD12).
    ///
    /// The v1 breadcrumb said "review your context and notes" — open-ended, which
    /// is what let restored agents grep every transcript and adopt a foreign one
    /// (Examples 2/3). When the binding verifies *and* carries a transcript path,
    /// this names that exact file so reconstruction is bounded to the right
    /// source. With no path, it degrades to the summary-only nudge (the verified
    /// session id still drove a correct native `--resume`).
    ///
    /// Like `breadcrumb(workspaceName:agent:)` the result is a single sanitized
    /// line, safe to inject as terminal startup input.
    static func breadcrumb(forVerified anchor: VerifiedResumeAnchor) -> String {
        let name = sanitizedName(anchor.workspaceName)
        let lead: String
        if let name {
            lead = "We were working on \"\(name)\" in this window last session."
        } else {
            lead = "We were working in this window last session."
        }
        if let path = sanitizedPath(anchor.transcriptPath) {
            return "\(lead) Your prior transcript for this window is at \(path) — review that file and pick up where we left off."
        }
        return "\(lead) Please review your context and notes, then pick up where we left off."
    }

    /// Verdict-gated breadcrumb: returns the transcript-anchored breadcrumb only
    /// for a `.verified` binding, and `nil` for any unverified one (R15 — a
    /// context-less / mis-mapped window gets no confident nudge; it routes to the
    /// honest cwd-scoped recovery in U11 instead). Encodes the "suppress when
    /// unverified" rule at the builder boundary so it is unit-testable.
    static func breadcrumbIfVerified(
        _ verdict: BindingVerdict,
        anchor: VerifiedResumeAnchor
    ) -> String? {
        guard verdict == .verified else { return nil }
        return breadcrumb(forVerified: anchor)
    }

    /// Builds the **honest, cwd-scoped** recovery prompt for an *unverified*
    /// restored window (U11/R14/KTD11) — the differentiated agent-first surface.
    ///
    /// When cmux cannot prove which session a restored window was running, it
    /// must not guess (Example 3's confident-wrong is the failure this kills) and
    /// must not surface a cross-session picker (a non-goal). Instead it tells the
    /// agent the truth: the prior session is unconfirmed, here is this window's
    /// folder, reconstruct *only if confident* from what's visibly here, else ask
    /// — and never adopt another window's session. This leans on the proven agent
    /// strength (bounded forensic recovery, Example 1) while refusing the
    /// open-ended grep-every-transcript behavior.
    ///
    /// Single sanitized line, safe to deliver as terminal startup input.
    static func honestRecoveryPrompt(workspaceName: String, cwd: String?) -> String {
        let name = sanitizedName(workspaceName)
        let folder = sanitizedPath(cwd)

        var sentence = "cmux restarted this window but could not verify which agent session it was running before"
        if let name {
            sentence += " (its last label was \"\(name)\")"
        }
        sentence += "."

        if let folder {
            sentence += " This window's working directory is \(folder)."
        }

        sentence += " If you can tell with confidence from the files here what was in progress, summarize it and continue; otherwise ask what I'd like to work on. Do not adopt or guess another window's session."
        return sentence
    }

    /// Collapses a raw transcript path into a safe single-line fragment for
    /// injection as terminal startup input. Paths may legitimately contain
    /// spaces, so internal whitespace is preserved (unlike `sanitizedName`); only
    /// control characters / newlines (which would submit the prompt early) are
    /// stripped, the tilde is expanded so the path is unambiguous, and length is
    /// bounded. Returns `nil` when nothing usable remains.
    static func sanitizedPath(_ raw: String?, maxLength: Int = 400) -> String? {
        guard let raw else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        var scalars = String.UnicodeScalarView()
        for scalar in expanded.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "\"" {
                continue
            }
            scalars.append(scalar)
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > maxLength {
            let clipped = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
            return clipped.isEmpty ? nil : clipped + "\u{2026}"
        }
        return cleaned
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
