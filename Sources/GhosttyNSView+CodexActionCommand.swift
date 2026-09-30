import AppKit
import CmuxTerminalCore
import GhosttyKit

extension GhosttyNSView {
    private var codexActionCacheRuntimeGeneration: UInt64 = .max
    private var codexActionCacheFrameSequence: UInt64 = .max
    private var codexActionCacheIsLiveCodexPanel = false
    private var codexActionCacheRows: [String]?

    private func codexActionCell(at point: NSPoint, surface: ghostty_surface_t) -> (TerminalPanel, CodexActionCommand)? {
        guard let terminalSurface, let panel = codexActionPanel(),
              refreshCodexActionCache(for: panel), bounds.contains(point) else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        var scrollbar = ghostty_surface_scrollbar_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), ghostty_surface_scrollbar(surface, &scrollbar), metrics.rows > 0, metrics.columns > 0,
              metrics.cell_width.isFinite, metrics.cell_width > 0,
              metrics.cell_height.isFinite, metrics.cell_height > 0,
              metrics.padding_left.isFinite, metrics.padding_top.isFinite,
              scrollbar.offset + scrollbar.len >= scrollbar.total else { return nil }
        let cellWidth = CGFloat(metrics.cell_width)
        let cellHeight = CGFloat(metrics.cell_height)
        let gridRect = NSRect(
            x: CGFloat(metrics.padding_left),
            y: bounds.height - CGFloat(metrics.padding_top) - CGFloat(metrics.rows) * cellHeight,
            width: CGFloat(metrics.columns) * cellWidth,
            height: CGFloat(metrics.rows) * cellHeight
        )
        guard gridRect.contains(point) else { return nil }
        let row = Int((gridRect.maxY - point.y) / cellHeight)
        guard row == Int(metrics.rows) - 1 else { return nil }
        let column = Int((point.x - gridRect.minX) / cellWidth)
        guard let renderedRows = codexActionCacheRows,
              row < renderedRows.count,
              let command = CodexActionCommandDetector().command(
                  in: renderedRows[row],
                  atColumn: column
              ) else { return nil }
        return (panel, command)
    }

    func codexActionCommand(at point: NSPoint, surface: ghostty_surface_t) -> CodexActionCommand? {
        codexActionCell(at: point, surface: surface)?.1
    }

    private func codexActionPanel() -> TerminalPanel? {
        guard let terminalSurface else { return nil }
        if let dock = DockSplitStore.liveStore(containingPanel: terminalSurface.id) {
            return dock.panels[terminalSurface.id] as? TerminalPanel
        }
        return terminalSurface.owningWorkspace()?.terminalPanel(for: terminalSurface.id)
    }

    private func refreshCodexActionCache(for panel: TerminalPanel) -> Bool {
        guard let terminalSurface else { return false }
        let runtimeGeneration = terminalSurface.runtimeSurfaceGeneration
        let frameSequence = renderedFrameSequence
        if runtimeGeneration == codexActionCacheRuntimeGeneration,
           frameSequence == codexActionCacheFrameSequence {
            return codexActionCacheIsLiveCodexPanel
        }
        codexActionCacheRuntimeGeneration = runtimeGeneration
        codexActionCacheFrameSequence = frameSequence
        codexActionCacheIsLiveCodexPanel = isLiveCodexPanel(panel)
        guard codexActionCacheIsLiveCodexPanel else {
            codexActionCacheRows = nil
            return false
        }
        codexActionCacheRows = terminalSurface.mobileRenderGridFrame(
            stateSeq: 0,
            includeTheme: false,
            anchor: .viewport
        )?.rows
        return codexActionCacheRows != nil
    }

    private func isLiveCodexPanel(_ panel: TerminalPanel) -> Bool {
        guard let terminalSurface else { return false }
        if let dock = DockSplitStore.liveStore(containingPanel: panel.id) {
            let snapshot = dock.restoredAgentLifecycle.snapshotsByPanelId[panel.id]
            let binding = dock.managedAgentResumeBinding(panelId: panel.id)
                ?? dock.surfaceResumeBinding(panelId: panel.id)
            guard binding?.isAgentHookBinding == true,
                  binding?.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex" else {
                return false
            }
            if binding?.launchFlavor.remoteContext != nil {
                return dock.detachedSurfaceTransfersByPanelId[panel.id]?.remoteTerminalSessionPhase == .connected
            }
            return dock.restoredAgentHasLiveProcess(
                panelId: panel.id,
                restoredAgent: snapshot
            )
        }
        guard let workspace = terminalSurface.owningWorkspace(),
              let binding = workspace.surfaceResumeBinding(panelId: panel.id),
              binding.isAgentHookBinding,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex",
              let agent = workspace.restoredAgentSnapshotsByPanelId[panel.id]
                ?? binding.managedRestorableAgentSnapshot(replacing: nil),
              agent.kind == .codex else {
            return false
        }
        if binding.launchFlavor.remoteContext != nil {
            return workspace.isRemoteTerminalSurface(panel.id)
                && workspace.remoteTerminalSessionStatesBySurfaceId[panel.id]?.phase == .connected
        }
        return workspace.restoredAgentHasLiveProcess(agent, panelId: panel.id)
    }

    @discardableResult
    func handleCodexActionCommand(at point: NSPoint, surface: ghostty_surface_t) -> Bool {
        guard let (panel, command) = codexActionCell(at: point, surface: surface) else { return false }
        return panel.sendInputResult(command.command + "\r").accepted
    }

    func updateCodexActionCommandHover(at point: NSPoint, surface: ghostty_surface_t) {
        let isHovering = codexActionCell(at: point, surface: surface) != nil
        guard isHovering != codexActionCommandHovering else { return }
        codexActionCommandHovering = isHovering
        window?.invalidateCursorRects(for: self)
    }
}
