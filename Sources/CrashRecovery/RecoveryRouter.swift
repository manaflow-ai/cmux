import Foundation

/// The window-scoped facts a restored window contributes to its recovery
/// decision *on top of* the verifiable binding facts: the display summary and
/// the working directory the window is restoring into. Kept separate from
/// `ResumeBindingFacts` (which is purely about whether the binding is
/// trustworthy) so the router can build the right human prompt for either branch
/// without the gate needing to know about names or folders.
nonisolated struct RecoveryContext: Equatable, Sendable {
    /// The window's persisted display name (auto- or user-set `customTitle`).
    var workspaceName: String
    /// The working directory the window is restoring into.
    var cwd: String?
    /// The verified transcript path, when the binding carried one. Kept as
    /// internal evidence only; user-facing breadcrumbs do not expose it.
    var transcriptPath: String?

    init(workspaceName: String, cwd: String?, transcriptPath: String? = nil) {
        self.workspaceName = workspaceName
        self.cwd = cwd
        self.transcriptPath = transcriptPath
    }
}

/// What a restored window should do — the binary, agent-first outcome. There are
/// exactly two branches by design (R14/R17): a verified binding resumes its own
/// session; an unverified one hands the agent an honest, bounded recovery prompt.
/// There is deliberately no third "pick a session from a list" branch — a
/// cross-session picker is a non-goal.
nonisolated enum RecoveryAction: Equatable, Sendable {
    /// The binding verified: drive the native `claude --resume <id>` (the caller
    /// already constructs the same-flag command) and, when breadcrumb injection
    /// is enabled, deliver `breadcrumb` once the agent is live. `breadcrumb` is
    /// nil when injection is disabled — native resume still runs.
    case resumeVerified(breadcrumb: String?)
    /// The binding could not be verified: deliver `prompt`, an honest cwd-scoped
    /// recovery prompt, and do **not** auto-resume anything. The agent
    /// reconstructs only if confident, else asks. `reason` is carried for logging
    /// and the offer/skip surfaces.
    case honestRecovery(prompt: String, reason: UnverifiedReason)
}

/// Routes a restored window to verified-resume or honest-bounded-recovery
/// (U11/KTD11) — the plan's differentiated, agent-first surface.
///
/// The router is the seam between the pure verification gate (U10) and the two
/// human-language builders (U12 verified breadcrumb, U11 honest prompt). It owns
/// no side effects: it turns "are these binding facts trustworthy?" into "resume
/// and say this" vs "don't resume, say this honestly instead."
///
/// It is consumed through `WorkspaceResumeCoordinator.recover(_:)`. Wiring that
/// `recover(_:)` into the live silent restore path — and the real `Workspace`
/// supplying on-disk verification facts — is the U14 step; until then the
/// conservative `ResumableWorkspaceSurface` defaults route every real restore to
/// honest recovery (never a blind resume). By contract neither delivery surface
/// may auto-resume an unverified binding, and neither enumerates sessions.
nonisolated struct RecoveryRouter {
    /// Whether to attach the breadcrumb on the verified branch (mirrors
    /// `WorkspaceResumePlanner.injectBreadcrumb`; native resume is unaffected).
    var injectBreadcrumb: Bool
    /// The verification gate (injectable; default is the standard gate).
    var gate: ResumeFidelityGate

    init(injectBreadcrumb: Bool, gate: ResumeFidelityGate = ResumeFidelityGate()) {
        self.injectBreadcrumb = injectBreadcrumb
        self.gate = gate
    }

    func route(_ facts: ResumeBindingFacts, context: RecoveryContext) -> RecoveryAction {
        switch gate.verify(facts) {
        case .verified:
            let breadcrumb: String? = injectBreadcrumb
                ? ResumeBreadcrumbBuilder.breadcrumb(
                    forVerified: ResumeBreadcrumbBuilder.VerifiedResumeAnchor(
                        workspaceName: context.workspaceName,
                        agentKind: facts.agentKind ?? .custom("unknown"),
                        transcriptPath: context.transcriptPath
                    )
                )
                : nil
            return .resumeVerified(breadcrumb: breadcrumb)

        case .unverified(let reason):
            let prompt = ResumeBreadcrumbBuilder.honestRecoveryPrompt(
                workspaceName: context.workspaceName,
                cwd: context.cwd
            )
            return .honestRecovery(prompt: prompt, reason: reason)
        }
    }

    /// Whether the router would auto-resume these facts. The default *silent*
    /// restore path gates on this so it never auto-resumes an unverified binding
    /// (R14): only a verified binding may resume without asking.
    func wouldAutoResume(_ facts: ResumeBindingFacts) -> Bool {
        gate.isVerified(facts)
    }
}
