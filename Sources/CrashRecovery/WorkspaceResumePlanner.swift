import Foundation

/// The resolvable facts about a restored workspace that decide whether it can be
/// auto-resumed and, if so, what breadcrumb to deliver. A plain value type with
/// no app coupling so the decision is unit-testable; the call sites (crash offer,
/// manual action) populate it from the live `Workspace` / resume binding.
nonisolated struct ResumeWorkspaceContext: Equatable, Sendable {
    /// The workspace's persisted display name (auto- or user-set `customTitle`).
    var workspaceName: String
    /// The agent kind backing the workspace, if known.
    var agentKind: RestorableAgentKind?
    /// The persisted agent session id, if any.
    var sessionId: String?
    /// Whether the restored resume binding is proven (a real, resumable session)
    /// vs. merely process-detected/unproven (see #6211/#6014 caution).
    var isResumeBindingProven: Bool

    init(
        workspaceName: String,
        agentKind: RestorableAgentKind?,
        sessionId: String?,
        isResumeBindingProven: Bool
    ) {
        self.workspaceName = workspaceName
        self.agentKind = agentKind
        self.sessionId = sessionId
        self.isResumeBindingProven = isResumeBindingProven
    }
}

/// What to do with a restored workspace.
nonisolated enum ResumeDecision: Equatable, Sendable {
    /// Resume the agent; deliver `breadcrumb` once it is live (nil when breadcrumb
    /// injection is disabled — native resume still runs).
    case resume(breadcrumb: String?)
    /// Do nothing; the reason is surfaced to the user (offer modal / disabled menu).
    case skip(ResumeBreadcrumbBuilder.SkipReason)
}

/// Pure decision core shared by the crash-recovery offer (U5) and the manual
/// per-workspace Resume action (U6). It never touches the terminal — delivery of
/// the breadcrumb (and the native resume itself) is the caller's concern. This
/// is the orchestrator's brain; keeping it side-effect free makes the full
/// skip-reason matrix testable without the app host.
nonisolated struct WorkspaceResumePlanner {
    /// Whether to attach the breadcrumb prompt when a workspace is resumable.
    var injectBreadcrumb: Bool

    init(injectBreadcrumb: Bool) {
        self.injectBreadcrumb = injectBreadcrumb
    }

    func decide(_ context: ResumeWorkspaceContext) -> ResumeDecision {
        // 1. Agent must be one v1 supports (Claude Code, Codex).
        guard let kind = context.agentKind, ResumeBreadcrumbBuilder.isSupported(kind) else {
            return .skip(.unsupportedAgent(context.agentKind ?? .custom("unknown")))
        }
        // 2. Need a session id to resume against.
        let trimmedSession = context.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionId = trimmedSession, !sessionId.isEmpty else {
            return .skip(.noSessionId)
        }
        // 3. Don't resume an unproven/process-detected session — that's the
        //    class of binding the in-flight resume PRs are still hardening.
        guard context.isResumeBindingProven else {
            return .skip(.unprovenSession)
        }
        // 4. Resumable. Attach the breadcrumb only when injection is enabled.
        let breadcrumb = injectBreadcrumb
            ? ResumeBreadcrumbBuilder.breadcrumb(workspaceName: context.workspaceName, agent: kind)
            : nil
        return .resume(breadcrumb: breadcrumb)
    }

    /// Convenience: partition a set of workspace contexts into the resumable ones
    /// (with their breadcrumbs) and the skipped ones (with reasons). Used by the
    /// offer modal to show "resume N, skip M" without duplicating the decision.
    func plan(_ contexts: [ResumeWorkspaceContext]) -> (resume: [(ResumeWorkspaceContext, String?)], skipped: [(ResumeWorkspaceContext, ResumeBreadcrumbBuilder.SkipReason)]) {
        var resume: [(ResumeWorkspaceContext, String?)] = []
        var skipped: [(ResumeWorkspaceContext, ResumeBreadcrumbBuilder.SkipReason)] = []
        for context in contexts {
            switch decide(context) {
            case .resume(let breadcrumb): resume.append((context, breadcrumb))
            case .skip(let reason): skipped.append((context, reason))
            }
        }
        return (resume, skipped)
    }
}
