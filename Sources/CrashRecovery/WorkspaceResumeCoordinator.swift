import Foundation

/// A live workspace surface that can be resumed. Abstracts the parts of
/// `Workspace`/`TerminalPanel` the coordinator needs, so the orchestration is
/// unit-testable with a fake and the real wiring stays thin glue.
@MainActor
protocol ResumableWorkspaceSurface: AnyObject {
    /// The workspace's display name (auto- or user-set), the breadcrumb anchor.
    var resumeWorkspaceName: String { get }
    /// The backing agent kind, if known.
    var resumeAgentKind: RestorableAgentKind? { get }
    /// A non-nil/non-empty token when there is a resume command to run (cmux's
    /// resume binding carries the command rather than a bare session id).
    var resumeSessionToken: String? { get }
    /// Whether the resume binding is proven (agent-hook/cli) vs. merely
    /// process-detected/unproven.
    var isResumeBindingProven: Bool { get }
    /// Whether an agent is already running in the surface (manual action on a
    /// live agent) vs. needing a native resume launch first.
    var isAgentLive: Bool { get }

    /// Re-run the agent's stored resume command to bring the agent back.
    func runNativeResume()
    /// Deliver the breadcrumb to the agent — immediately if live, else when the
    /// surface becomes ready.
    func deliverResumeBreadcrumb(_ text: String)
}

/// The outcome of attempting to resume a single workspace.
enum ResumeOutcome: Equatable, Sendable {
    case resumed(deliveredBreadcrumb: Bool)
    case skipped(ResumeBreadcrumbBuilder.SkipReason)
}

/// Shared orchestration for "pick up where we left off", used by both the
/// crash-recovery offer (U5) and the manual per-workspace action (U6). It maps a
/// live surface into the pure `WorkspaceResumePlanner` decision, then performs
/// the native resume (when needed) and breadcrumb delivery. The decision logic
/// lives in the planner; this layer is the thin, MainActor performer.
@MainActor
struct WorkspaceResumeCoordinator {
    let planner: WorkspaceResumePlanner

    init(injectBreadcrumb: Bool) {
        self.planner = WorkspaceResumePlanner(injectBreadcrumb: injectBreadcrumb)
    }

    /// Build the planner context from a live surface.
    func context(for surface: ResumableWorkspaceSurface) -> ResumeWorkspaceContext {
        ResumeWorkspaceContext(
            workspaceName: surface.resumeWorkspaceName,
            agentKind: surface.resumeAgentKind,
            sessionId: surface.resumeSessionToken,
            isResumeBindingProven: surface.isResumeBindingProven
        )
    }

    /// Decide without performing — used to enable/disable the manual action.
    func canResume(_ surface: ResumableWorkspaceSurface) -> Bool {
        if case .resume = planner.decide(context(for: surface)) { return true }
        return false
    }

    /// Resume the surface: native resume if the agent isn't live, then deliver the
    /// breadcrumb (if injection is on). Never clobbers — a non-resumable surface
    /// is left untouched and the reason returned.
    @discardableResult
    func resume(_ surface: ResumableWorkspaceSurface) -> ResumeOutcome {
        switch planner.decide(context(for: surface)) {
        case .skip(let reason):
            return .skipped(reason)
        case .resume(let breadcrumb):
            if !surface.isAgentLive {
                surface.runNativeResume()
            }
            if let breadcrumb {
                surface.deliverResumeBreadcrumb(breadcrumb)
            }
            return .resumed(deliveredBreadcrumb: breadcrumb != nil)
        }
    }
}
