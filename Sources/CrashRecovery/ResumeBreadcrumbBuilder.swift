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
/// input*, so it is sanitized to a single shell-inert line (embedded newlines
/// would submit the prompt prematurely, and shell metacharacters could expand if
/// a queued prompt ever falls through to a shell).
enum ResumeBreadcrumbBuilder {
    private static let shellMetacharacters: Set<UnicodeScalar> = [
        "\"", "'", "`", "$", "\\", ";", "|", "&", "<", ">",
        "(", ")", "{", "}", "[", "]", "*", "!", "?", "#",
    ]

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
            case .unsupportedAgent: return "resume not supported for this agent type"
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
        if let name {
            return String.localizedStringWithFormat(
                String(
                    localized: "crashRecovery.breadcrumb.named",
                    defaultValue: "We were working on \"%@\" in this window last session. Please review your context and notes, then pick up where we left off."
                ),
                name
            ).sanitizedTerminalStartupInputLine()
        }
        return String(
            localized: "crashRecovery.breadcrumb.unnamed",
            defaultValue: "We were working in this window last session. Please review your context and notes, then pick up where we left off."
        ).sanitizedTerminalStartupInputLine()
    }

    /// A *verified* restored binding's anchor for the forensic-recovery
    /// breadcrumb (U12/R15): the window's summary, its agent, and — when known —
    /// the internal transcript evidence that `ResumeFidelityGate` confirmed
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

    /// Builds the breadcrumb for a *verified* restored binding.
    ///
    /// The verified session id already drove the correct native `--resume`, so
    /// the user-facing breadcrumb stays privacy-safe: it anchors on the workspace
    /// label and asks the resumed agent to review its restored context without
    /// exposing vendor transcript paths or session-derived filenames.
    ///
    /// Like `breadcrumb(workspaceName:agent:)` the result is a single sanitized
    /// line, safe to inject as terminal startup input.
    static func breadcrumb(forVerified anchor: VerifiedResumeAnchor) -> String {
        breadcrumb(workspaceName: anchor.workspaceName, agent: anchor.agentKind)
    }

    /// Verdict-gated breadcrumb: returns the verified breadcrumb only
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

        switch (name, folder) {
        case (.some(let name), .some(let folder)):
            return String.localizedStringWithFormat(
                String(
                    localized: "crashRecovery.honestRecovery.namedWithCwd",
                    defaultValue: "cmux restarted this window but could not verify which agent session it was running before (its last label was \"%1$@\"). This window's working directory is %2$@. If you can tell with confidence from the files here what was in progress, summarize it and continue; otherwise ask what I'd like to work on. Do not adopt or guess another window's session."
                ),
                name,
                folder
            ).sanitizedTerminalStartupInputLine()
        case (.some(let name), .none):
            return String.localizedStringWithFormat(
                String(
                    localized: "crashRecovery.honestRecovery.namedNoCwd",
                    defaultValue: "cmux restarted this window but could not verify which agent session it was running before (its last label was \"%@\"). If you can tell with confidence from the files here what was in progress, summarize it and continue; otherwise ask what I'd like to work on. Do not adopt or guess another window's session."
                ),
                name
            ).sanitizedTerminalStartupInputLine()
        case (.none, .some(let folder)):
            return String.localizedStringWithFormat(
                String(
                    localized: "crashRecovery.honestRecovery.unnamedWithCwd",
                    defaultValue: "cmux restarted this window but could not verify which agent session it was running before. This window's working directory is %@. If you can tell with confidence from the files here what was in progress, summarize it and continue; otherwise ask what I'd like to work on. Do not adopt or guess another window's session."
                ),
                folder
            ).sanitizedTerminalStartupInputLine()
        case (.none, .none):
            return String(
                localized: "crashRecovery.honestRecovery.unnamedNoCwd",
                defaultValue: "cmux restarted this window but could not verify which agent session it was running before. If you can tell with confidence from the files here what was in progress, summarize it and continue; otherwise ask what I'd like to work on. Do not adopt or guess another window's session."
            ).sanitizedTerminalStartupInputLine()
        }
    }

    /// Collapses a raw path into a safe single-line fragment for
    /// injection as terminal startup input. Paths may legitimately contain
    /// spaces, so internal whitespace is preserved (unlike `sanitizedName`); only
    /// line-breaking scalars are stripped, the tilde is expanded so the path is
    /// unambiguous, and length is bounded. Returns `nil` when nothing usable
    /// remains.
    ///
    /// Newline neutralization must cover the Unicode line/paragraph separators
    /// U+2028/U+2029 (category Zl/Zp — *not* in `controlCharacters`), which some
    /// terminals/agents treat as a line break and would submit the prompt early.
    /// `sanitizedName` gets this for free via its `.whitespacesAndNewlines` split;
    /// this path-preserving variant has no such split, so it filters
    /// `CharacterSet.newlines` (which includes U+2028/U+2029) explicitly.
    static func sanitizedPath(_ raw: String?, maxLength: Int = 400) -> String? {
        guard let raw else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        var scalars = String.UnicodeScalarView()
        for scalar in expanded.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || shellMetacharacters.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
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
    /// - Replaces shell metacharacters so queued prompts cannot trigger shell
    ///   expansion if they fall through to a shell.
    /// - Collapses runs of whitespace and trims.
    /// - Caps length to keep the injected line bounded.
    static func sanitizedName(_ raw: String, maxLength: Int = 120) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || shellMetacharacters.contains(scalar) {
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

    /// Collapses a finished prompt to one line and strips shell syntax from both
    /// template text and interpolated fragments. If a queued agent prompt falls
    /// through to an interactive shell, the shell may attempt to run a harmless
    /// prose command, but it will not expand user-controlled substitutions or
    /// operators first.
    static func sanitizedTerminalStartupInputLine(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || shellMetacharacters.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private extension String {
    func sanitizedTerminalStartupInputLine() -> String {
        ResumeBreadcrumbBuilder.sanitizedTerminalStartupInputLine(self)
    }
}
