#if DEBUG
import AppKit
import CmuxTerminal
import CmuxTestSupport
import Foundation

/// Live-state conformance for the DEBUG stress-workspace harness.
///
/// ``DebugStressWorkspaceDriver`` owns the harness orchestration (creation loop,
/// timing, stats, the notification wait primitive, and every log line) in the
/// `CmuxTestSupport` package. This extension supplies the operations that touch
/// live `Workspace` / `TabManager` / `TerminalPanel` / `NSWindow` state, which
/// cannot cross the package boundary. The bodies are a faithful lift of the
/// former `AppDelegate` stress methods (`configureDebugStressWorkspaceLayout`,
/// the panel-enumeration and surface-start passes inside
/// `loadAllDebugStressWorkspacesForTerminalSurfaceReadiness`,
/// `waitForDebugStressMountedWorkspaces`,
/// `waitForDebugStressTerminalPanelSurfaces`, `forceDebugStressVisibleLayout`,
/// and `pendingDebugTerminalSurfaceCount`); the driver addresses the live
/// objects through the opaque handles minted here.
extension AppDelegate: DebugStressWorkspaceHosting {
    var canRunStressHarness: Bool {
        tabManager != nil
    }

    func enableStressLagProbe() {
        debugStressLagProbeEnabled = true
    }

    func currentSelectedWorkspaceID() -> UUID? {
        tabManager?.selectedTabId
    }

    func restoreSelectedWorkspace(_ id: UUID) {
        guard let tabManager,
              tabManager.tabs.contains(where: { $0.id == id }) else {
            return
        }
        tabManager.selectedTabId = id
    }

    func createStressWorkspace(oneBasedIndex: Int) -> DebugStressWorkspaceHandle {
        guard let tabManager else {
            return DebugStressWorkspaceHandle(id: UUID())
        }
        let workspace = tabManager.addWorkspace(select: false, placementOverride: .end)
        tabManager.setCustomTitle(
            tabId: workspace.id,
            title: "\(DebugStressWorkspaceConfiguration.standard.workspaceTitlePrefix)\(oneBasedIndex)"
        )
        return DebugStressWorkspaceHandle(id: workspace.id)
    }

    func configureStressWorkspaceLayout(
        _ handle: DebugStressWorkspaceHandle,
        paneCount: Int,
        tabsPerPane: Int,
        yieldInterval: Int
    ) async -> Bool {
        guard let workspace = stressWorkspace(for: handle) else { return false }
        guard let topLeftPanelId = workspace.focusedTerminalPanel?.id ?? workspace.focusedPanelId else {
            return false
        }
        guard let topRight = workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topRight.id,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()

        let paneIds = workspace.bonsplitController.allPaneIds
        guard paneIds.count == paneCount else { return false }

        let additionalTabsPerPane = max(0, tabsPerPane - 1)
        if additionalTabsPerPane > 0 {
            for (paneIndex, paneId) in paneIds.enumerated() {
                for tabOffset in 0..<additionalTabsPerPane {
                    guard workspace.newTerminalSurface(inPane: paneId, focus: false) != nil else {
                        return false
                    }
                    if ((tabOffset + 1) % yieldInterval) == 0 {
                        await Task.yield()
                    }
                }
                if ((paneIndex + 1) % yieldInterval) == 0 {
                    await Task.yield()
                }
            }
        }

        return true
    }

    func pendingTerminalSurfaceCount(in handles: [DebugStressWorkspaceHandle]) -> Int {
        var pending = 0
        for workspace in stressWorkspaces(for: handles) {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                if terminalPanel.surface.surface == nil {
                    pending += 1
                }
            }
        }
        return pending
    }

    func retainStressWorkspaceLoads(_ handles: [DebugStressWorkspaceHandle]) {
        tabManager?.retainDebugWorkspaceLoads(for: Set(handles.map(\.id)))
    }

    func releaseStressWorkspaceLoads(_ handles: [DebugStressWorkspaceHandle]) {
        tabManager?.releaseDebugWorkspaceLoads(for: Set(handles.map(\.id)))
    }

    func forceStressVisibleLayout() {
        if let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            activeWindow.contentView?.layoutSubtreeIfNeeded()
            activeWindow.contentView?.displayIfNeeded()
            return
        }

        for (windowIndex, window) in NSApp.windows.enumerated() {
            window.contentView?.layoutSubtreeIfNeeded()
            if windowIndex == 0 {
                window.contentView?.displayIfNeeded()
            }
        }
    }

    func mountedStressWorkspaceCount(in handles: [DebugStressWorkspaceHandle]) -> Int {
        let workspaces = stressWorkspaces(for: handles)
        guard !workspaces.isEmpty else { return 0 }
        let selectedWorkspaceId = tabManager?.selectedTabId
        forceStressVisibleLayout()
        var mountedWorkspaceCount = 0
        for workspace in workspaces {
            if workspace.id == selectedWorkspaceId {
                workspace.scheduleDebugStressTerminalGeometryReconcile()
            } else {
                workspace.panels.values.compactMap { $0 as? TerminalPanel }.forEach { $0.surface.requestBackgroundSurfaceStartIfNeeded() }
            }
            if workspace.panels.values.contains(where: { panel in
                guard let terminalPanel = panel as? TerminalPanel else { return false }
                return terminalPanel.hostedView.superview != nil || terminalPanel.surface.surface != nil
            }) {
                mountedWorkspaceCount += 1
            }
        }
        return mountedWorkspaceCount
    }

    func queueStressTerminalLoadTargets(
        in handles: [DebugStressWorkspaceHandle],
        perWorkspace: (_ workspaceIndex: Int, _ queuedSoFar: Int) async -> Void
    ) async -> [DebugStressLoadTargetHandle] {
        debugStressLoadTargets.removeAll()
        var queuedHandles: [DebugStressLoadTargetHandle] = []

        for (workspaceIndex, workspace) in stressWorkspaces(for: handles).enumerated() {
            for paneId in workspace.bonsplitController.allPaneIds {
                for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                    guard let panelId = workspace.panelIdFromSurfaceId(tab.id),
                          workspace.panel(for: tab.id) is TerminalPanel else {
                        continue
                    }
                    if workspace.preloadTerminalPanelForDebugStress(tabId: tab.id, inPane: paneId) != nil {
                        let targetHandle = DebugStressLoadTargetHandle(rawValue: UUID())
                        debugStressLoadTargets[targetHandle.rawValue] = DebugStressTerminalLoadTarget(
                            workspace: workspace,
                            paneId: paneId,
                            tabId: tab.id,
                            panelId: panelId
                        )
                        queuedHandles.append(targetHandle)
                    }
                }
            }

            await perWorkspace(workspaceIndex, queuedHandles.count)
        }

        return queuedHandles
    }

    func refreshStressPendingTargets(
        _ targets: [DebugStressLoadTargetHandle]
    ) -> (pending: [DebugStressLoadTargetHandle], started: Int) {
        forceStressVisibleLayout()
        let selectedWorkspaceId = tabManager?.selectedTabId
        var nextPending: [DebugStressLoadTargetHandle] = []
        nextPending.reserveCapacity(targets.count)
        var startedThisPass = 0

        for targetHandle in targets {
            guard let target = debugStressLoadTargets[targetHandle.rawValue] else {
                continue
            }
            guard let terminalPanel = target.workspace.panel(for: target.tabId) as? TerminalPanel else {
                nextPending.append(targetHandle)
                continue
            }
            if terminalPanel.surface.surface != nil {
                continue
            }

            let hostedView = terminalPanel.hostedView
            let shouldReconcileVisibleSelection =
                target.workspace.id == selectedWorkspaceId &&
                terminalPanel.surface.isViewInWindow &&
                hostedView.superview != nil

            if shouldReconcileVisibleSelection {
                target.workspace.scheduleDebugStressTerminalGeometryReconcile()
                terminalPanel.requestViewReattach()
            }
            terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            startedThisPass += 1
            nextPending.append(targetHandle)
        }

        return (pending: nextPending, started: startedThisPass)
    }

    func installStressSurfaceReadinessObservers(
        trigger: @escaping () -> Void
    ) -> [any NSObjectProtocol] {
        [
            NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { _ in
                trigger()
            },
            NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { _ in
                trigger()
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: nil,
                queue: .main
            ) { _ in
                trigger()
            }
        ]
    }

    func removeStressSurfaceReadinessObservers(_ tokens: [any NSObjectProtocol]) {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func logIdentifier(for handle: DebugStressLoadTargetHandle) -> String {
        guard let target = debugStressLoadTargets[handle.rawValue] else {
            return "workspace=? panel=? pane=?"
        }
        return "workspace=\(target.workspace.id.uuidString.prefix(5)) " +
            "panel=\(target.panelId.uuidString.prefix(5)) pane=\(target.paneId.id.uuidString.prefix(5))"
    }

    private func stressWorkspace(for handle: DebugStressWorkspaceHandle) -> Workspace? {
        tabManager?.tabs.first(where: { $0.id == handle.id })
    }

    private func stressWorkspaces(for handles: [DebugStressWorkspaceHandle]) -> [Workspace] {
        guard let tabManager else { return [] }
        let byId = Dictionary(tabManager.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return handles.compactMap { byId[$0.id] }
    }
}
#endif
