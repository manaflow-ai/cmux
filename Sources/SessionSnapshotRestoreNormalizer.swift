import CmuxPanes
import Foundation

/// Admits saved containers against the resources the runtime will create.
/// Every workspace costs at least its fallback main terminal. A Dock has no
/// fallback terminal; an explicit empty Dock also suppresses configuration seeding.
struct SessionSnapshotRestoreNormalizer {
    func normalize(
        _ snapshot: AppSessionSnapshot,
        report: inout SessionSnapshotImportTrustReport
    ) -> AppSessionSnapshot {
        var result = snapshot
        var panelBudget = SessionPersistencePolicy.maxPanelsPerSnapshot
        var layouts = SessionLayoutRestoreNormalizer(
            maximumNodes: SessionPersistencePolicy.maxLayoutNodes,
            maximumDepth: SessionPersistencePolicy.maxLayoutDepth
        )
        var admittedPanelIDs = Set<UUID>()
        var windows: [SessionWindowSnapshot] = []
        let admittedWindows = snapshot.windows.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot)
        report.droppedWindowCount += snapshot.windows.count - admittedWindows.count
        for window in snapshot.windows.dropFirst(admittedWindows.count) {
            report.droppedWorkspaceCount += window.tabManager.workspaces.count
            report.droppedPanelCount += panelCount(in: window)
        }
        for var window in admittedWindows {
            // TabManager also creates a fallback workspace for a dock-only or
            // empty pinned-group window. Do not create a window after exhaustion.
            guard panelBudget > 0 else {
                report.droppedWindowCount += 1
                report.droppedWorkspaceCount += window.tabManager.workspaces.count
                report.droppedPanelCount += panelCount(in: window)
                continue
            }
            let original = window.tabManager.workspaces
            for workspace in original.dropFirst(SessionPersistencePolicy.maxWorkspacesPerWindow) {
                report.droppedPanelCount += workspace.panels.count + (workspace.dock?.panels.count ?? 0)
            }
            var workspaces: [SessionWorkspaceSnapshot] = []
            for var workspace in original.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
                guard panelBudget > 0 else {
                    report.droppedPanelCount += workspace.panels.count + (workspace.dock?.panels.count ?? 0)
                    continue
                }
                var fallbackBudgetCharged = false
                if workspace.panels.isEmpty {
                    panelBudget -= 1
                    fallbackBudgetCharged = true
                } else {
                    workspace.panels = admittedPanels(
                        workspace.panels,
                        budget: &panelBudget,
                        admittedPanelIDs: &admittedPanelIDs,
                        report: &report
                    )
                    if workspace.panels.isEmpty {
                        // A duplicate-only workspace still causes TabManager
                        // to create its fallback terminal.
                        panelBudget -= 1
                        fallbackBudgetCharged = true
                    }
                }
                let normalized = layouts.normalize(workspace.layout, panelIDs: workspace.panels.map(\.id))
                workspace.layout = normalized.layout
                if !normalized.droppedPanelIDs.isEmpty {
                    panelBudget += normalized.droppedPanelIDs.count
                    workspace.panels.removeAll { normalized.droppedPanelIDs.contains($0.id) }
                    report.droppedPanelCount += normalized.droppedPanelIDs.count
                }
                if workspace.panels.isEmpty && !fallbackBudgetCharged {
                    // Layout admission can remove every panel from an
                    // otherwise non-empty workspace. Restore still creates
                    // its fallback terminal, so charge it after normalization.
                    panelBudget -= 1
                }
                if let dock = workspace.dock {
                    workspace.dock = normalizedDock(
                        dock,
                        budget: &panelBudget,
                        admittedPanelIDs: &admittedPanelIDs,
                        layouts: &layouts,
                        report: &report
                    )
                }
                workspaces.append(workspace)
            }
            report.droppedWorkspaceCount += original.count - workspaces.count
            if workspaces.count != original.count {
                // Admission keeps a prefix, so every surviving group member and
                // its anchor index retain their position. TabManager already
                // validates an anchor that points past the retained prefix.
                if let selection = window.tabManager.selectedWorkspaceIndex {
                    window.tabManager.selectedWorkspaceIndex = workspaces.isEmpty
                        ? nil : min(max(0, selection), workspaces.count - 1)
                }
            }
            window.tabManager.workspaces = workspaces
            if workspaces.isEmpty { panelBudget -= 1 }
            if let dock = window.dock {
                window.dock = normalizedDock(
                    dock,
                    budget: &panelBudget,
                    admittedPanelIDs: &admittedPanelIDs,
                    layouts: &layouts,
                    report: &report
                )
            }
            windows.append(window)
        }
        result.windows = windows
        return result
    }

    private func admittedPanels(
        _ panels: [SessionPanelSnapshot],
        budget: inout Int,
        admittedPanelIDs: inout Set<UUID>,
        report: inout SessionSnapshotImportTrustReport
    ) -> [SessionPanelSnapshot] {
        let maximum = min(SessionPersistencePolicy.maxPanelsPerWorkspace, budget)
        var result: [SessionPanelSnapshot] = []
        result.reserveCapacity(min(panels.count, maximum))
        for panel in panels {
            guard result.count < maximum else {
                report.droppedPanelCount += 1
                continue
            }
            guard admittedPanelIDs.insert(panel.id).inserted else {
                report.droppedPanelCount += 1
                continue
            }
            result.append(panel)
        }
        budget -= result.count
        return result
    }

    private func normalizedDock(
        _ dock: SessionSplitContainerSnapshot,
        budget: inout Int,
        admittedPanelIDs: inout Set<UUID>,
        layouts: inout SessionLayoutRestoreNormalizer,
        report: inout SessionSnapshotImportTrustReport
    ) -> SessionSplitContainerSnapshot {
        var result = dock
        result.panels = admittedPanels(
            dock.panels,
            budget: &budget,
            admittedPanelIDs: &admittedPanelIDs,
            report: &report
        )
        let normalized = layouts.normalize(dock.layout, panelIDs: result.panels.map(\.id))
        result.layout = normalized.layout
        if !normalized.droppedPanelIDs.isEmpty {
            budget += normalized.droppedPanelIDs.count
            result.panels.removeAll { normalized.droppedPanelIDs.contains($0.id) }
            report.droppedPanelCount += normalized.droppedPanelIDs.count
        }
        return result
    }

    private func panelCount(in window: SessionWindowSnapshot) -> Int {
        window.tabManager.workspaces.reduce(window.dock?.panels.count ?? 0) {
            $0 + $1.panels.count + ($1.dock?.panels.count ?? 0)
        }
    }
}
