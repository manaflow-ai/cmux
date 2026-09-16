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
        guard let workspaceID, let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) else {
            return .init(transition: transition)
        }
        return .init(
            transition: transition,
            population: .window,
            workspaceCount: manager.tabs.count,
            surfaceCount: manager.tabs.reduce(0) { $0 + $1.panels.count }
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
