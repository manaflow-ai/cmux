import AppKit
import CMUXMobileCore
import CmuxTerminal

/// App boundary for privacy-safe snapshots; it never reads terminal contents.
@MainActor
struct TerminalGeometryDiagnostics {
    func context(
        workspaceID: UUID?,
        transition: TerminalWorkContext.Transition
    ) -> TerminalWorkContext {
        guard let workspaceID,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?.workspacesById[workspaceID] else {
            return .init(transition: transition)
        }
        // Per-surface layout must not enumerate every workspace in the window.
        // The existing ownership index and Dictionary.count keep this snapshot
        // independent of the number of other workspaces and panels.
        return .init(
            transition: transition,
            population: .workspace,
            workspaceCount: 1,
            surfaceCount: workspace.panels.count
        )
    }

    func begin(
        _ phase: TerminalWorkDiagnostic.Phase,
        workspaceID: UUID?,
        transition: TerminalWorkContext.Transition = .unknown
    ) -> TerminalWorkInterval {
        MobileHostDiagnostics.log.beginTerminalWork(
            phase, context: context(workspaceID: workspaceID, transition: transition)
        )
    }

    /// Only an active native window or owned divider drag establishes resize.
    func resizeTransition(in window: NSWindow?) -> TerminalWorkContext.Transition {
        guard let window else { return .unknown }
        return window.inLiveResize || TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: window)
            ? .resize : .unknown
    }

    func refresh(_ view: GhosttySurfaceScrollView, reason: String) {
        let work = begin(
            .rendererRefresh,
            workspaceID: view.surfaceView.terminalSurface?.tabId,
            transition: reason.contains("reveal") ? .reveal : .unknown
        )
        defer { work.end() }
        // Retain the existing realization boundary while measuring its cost.
        view.layoutSubtreeIfNeeded()
        view.surfaceView.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.surfaceView.displayIfNeeded()
        view.surfaceView.terminalSurface?.forceRefresh(reason: reason)
    }
}
