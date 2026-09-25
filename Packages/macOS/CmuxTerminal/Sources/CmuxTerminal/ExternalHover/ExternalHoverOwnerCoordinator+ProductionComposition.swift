public import CmuxTerminalCore
internal import Foundation

extension RenderDemandActivationTracker {
    /// (C) ExternalHover diagnostics — review round3 B2: the ONE function
    /// that constructs an `ExternalHoverOwnerCoordinator` wired to THIS
    /// tracker's `manageDiagnosticsRenderDemand`. `GhosttyNSView` and
    /// tests both call this factory instead of each writing their own
    /// `{ active in tracker.setActive(active) }` closure literal — two
    /// call sites independently writing the same one-liner is STILL "the
    /// test doesn't exercise production wiring" (the review's own
    /// words), since nothing stops one side from drifting (e.g.
    /// reintroducing a `DispatchQueue.main.async` hop) while the other
    /// stays green. Only a function neither caller can diverge from
    /// closes that gap.
    ///
    /// `manageDiagnosticsRenderDemand` is therefore hardwired to
    /// `setActive` here, NEVER a parameter — that is precisely the one
    /// piece of wiring this factory exists to pin down. `diagnosticsEnabled`
    /// IS a parameter: production and tests legitimately need different
    /// gates (the real process-wide `ExternalHoverDiagnosticsGate` vs. a
    /// controllable test double), and that choice has nothing to do with
    /// the render-demand race this factory closes.
    public func makeExternalHoverOwnerCoordinator(
        scheduler: @escaping ExternalHoverOwnerCoordinator.Scheduler,
        project: @escaping ExternalHoverOwnerCoordinator.Project,
        logTransition: @escaping ExternalHoverOwnerCoordinator.LogTransition = { _ in },
        diagnosticsEnabled: @escaping ExternalHoverOwnerCoordinator.DiagnosticsEnabled = {
            ExternalHoverDiagnosticsGate.isEnabled
        }
    ) -> ExternalHoverOwnerCoordinator {
        ExternalHoverOwnerCoordinator(
            scheduler: scheduler,
            project: project,
            manageDiagnosticsRenderDemand: setActive,
            logTransition: logTransition,
            diagnosticsEnabled: diagnosticsEnabled
        )
    }
}
