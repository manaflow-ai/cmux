import Foundation

/// The verifiable facts about a restored window↔session binding that decide
/// whether the binding can be *trusted* enough to drive a native `--resume` and
/// the "pick up where we left off" breadcrumb (U10/R13).
///
/// This is deliberately a plain value type with no app or filesystem coupling so
/// the decision is exhaustively unit-testable. The two on-disk facts —
/// `transcriptExistsAtWindowCwd` and `transcriptExistsElsewhere` — are produced
/// by a thin adapter at the restore call site (the real `Workspace` overrides
/// `ResumableWorkspaceSurface`'s defaulted verification facts with the on-disk
/// transcript lookup; that override + its live validation are the U14 step). The
/// gate itself never reads a file — keeping the filesystem at the edge is what
/// lets the full verified/unverified matrix be proven without the app host.
nonisolated struct ResumeBindingFacts: Equatable, Sendable {
    /// Whether *any* binding was persisted for this restored panel. A panel that
    /// never recorded a session (the common "[no agent]" pre-crash pane, U9)
    /// has no binding at all and must not be guessed at.
    var hasBinding: Bool
    /// The agent kind backing the binding, if known.
    var agentKind: RestorableAgentKind?
    /// The persisted agent session id.
    var sessionId: String?
    /// Whether a native resume command can be constructed for this binding
    /// (resolved by the adapter from the recorded launch command / kind).
    var resumeCommandConstructable: Bool
    /// Whether a transcript for `sessionId` exists on disk **at the project
    /// directory derived from this window's own cwd** (Claude:
    /// `~/.claude/projects/<encode(windowCwd)>/<id>.jsonl`). True here means the
    /// transcript exists *and* its storage location matches this window — the
    /// two checks collapse into one for cwd-namespaced agents.
    var transcriptExistsAtWindowCwd: Bool
    /// Whether a transcript for `sessionId` exists on disk under some *other*
    /// project directory (a different cwd). Distinguishes "no transcript at all"
    /// (`.transcriptMissing`) from "transcript exists but belongs to a different
    /// working directory" (`.cwdMismatch`) — the anti-Example-3 case where the
    /// restore would otherwise grep every transcript and adopt a foreign one.
    var transcriptExistsElsewhere: Bool

}

/// The outcome of verifying a restored binding.
nonisolated enum BindingVerdict: Equatable, Sendable {
    /// The binding is trustworthy: resume this exact session and deliver the
    /// privacy-safe breadcrumb (U11 verified path → U12).
    case verified
    /// The binding could not be trusted; the reason routes the restore to the
    /// honest, cwd-scoped agent recovery (U11 unverified path). Never resumed,
    /// never silently presented as fact.
    case unverified(UnverifiedReason)
}

/// Why a restored binding failed verification. Stable raw form for logging and
/// tests; localized at the display call site.
nonisolated enum UnverifiedReason: Hashable, Sendable {
    /// No binding was persisted for this panel — nothing to verify.
    case noBinding
    /// A binding exists but carries no usable session id.
    case noSessionId
    /// The agent is outside the supported resume set (Claude, Codex in v1).
    case unsupportedAgent(RestorableAgentKind)
    /// A session id exists but no native resume command could be built for it.
    case resumeUnavailable
    /// No transcript for the session id exists anywhere on disk.
    case transcriptMissing
    /// A transcript exists, but under a different working directory than this
    /// window — adopting it would mis-attribute a foreign session (Example 3).
    case cwdMismatch

    /// Short, user-facing reason. Localized at the call site for display; this
    /// raw form is stable for logging and tests.
    var debugDescription: String {
        switch self {
        case .noBinding: return "no saved session binding for this window"
        case .noSessionId: return "saved binding had no agent session id"
        case .unsupportedAgent: return "resume not supported for this agent type"
        case .resumeUnavailable: return "no resume command could be built for the saved session"
        case .transcriptMissing: return "no transcript found on disk for the saved session"
        case .cwdMismatch: return "the saved session belongs to a different working directory"
        }
    }
}

/// Pure verification core for a restored window↔session binding (U10/R13).
///
/// "Verify before trusting": the live failures this plan targets were all
/// *unverified trust* — a fresh window wearing a name it never earned, a
/// `--resume` against a session that wasn't this window's, a confident recovery
/// of a transcript found by grepping every project. The gate refuses every one
/// of those by demanding, in order: a binding exists, the agent is supported, a
/// session id and a constructable resume command are present, and the
/// transcript exists *at this window's own cwd* (not merely somewhere on disk).
///
/// Side-effect free by construction. The single `verify` entry point mirrors
/// `WorkspaceResumePlanner.decide` — same shape, same testability contract.
nonisolated struct ResumeFidelityGate {

    /// Agents whose native-resume + verification flow v1 supports. Mirrors
    /// `ResumeBreadcrumbBuilder.isSupported` so the gate and the breadcrumb agree
    /// on the supported set.
    static func isSupported(_ kind: RestorableAgentKind) -> Bool {
        ResumeBreadcrumbBuilder.isSupported(kind)
    }

    func verify(_ facts: ResumeBindingFacts) -> BindingVerdict {
        // 1. A binding must have been persisted for this panel at all. A pane
        //    that came up "[no agent]" pre-crash has nothing to verify — it falls
        //    to U11's honest cwd-scoped recovery, never a guess.
        guard facts.hasBinding else { return .unverified(.noBinding) }

        // 2. The agent must be one whose resume + transcript layout we understand.
        guard let kind = facts.agentKind, Self.isSupported(kind) else {
            return .unverified(.unsupportedAgent(facts.agentKind ?? .custom("unknown")))
        }

        // 3. A non-empty session id is the thing we resume against.
        let trimmedSession = facts.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionId = trimmedSession, !sessionId.isEmpty else {
            return .unverified(.noSessionId)
        }

        // 4. A native resume command must be constructable for it.
        guard facts.resumeCommandConstructable else {
            return .unverified(.resumeUnavailable)
        }

        // 5. The transcript must exist *at this window's own cwd*. If it exists
        //    only under a different project dir, the binding points at a session
        //    that belongs to another working directory — that is the confident
        //    mis-attribution (Example 3) we refuse, not a verified resume.
        guard facts.transcriptExistsAtWindowCwd else {
            return .unverified(facts.transcriptExistsElsewhere ? .cwdMismatch : .transcriptMissing)
        }

        return .verified
    }

    /// Convenience: a binding is trustworthy iff it verifies.
    func isVerified(_ facts: ResumeBindingFacts) -> Bool {
        verify(facts) == .verified
    }
}
