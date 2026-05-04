import Foundation

enum MainWindowMainPanelFocusSource: Equatable {
    case keyboardShortcut
    case pointer
    case terminalFirstResponder
    case responderSync
    case programmatic
}

extension MainWindowFocusController {
    func allowsTerminalFocus(workspaceId: UUID, panelId: UUID) -> Bool {
        if TerminalSurfaceRegistry.shared.isRightSidebarDockSurface(id: panelId) {
            return true
        }
        guard workspaceContainsPanel(workspaceId: workspaceId, panelId: panelId) else {
            return false
        }
        if hasPendingRightSidebarFocusRequest {
            return false
        }
        switch intent {
        case .rightSidebar:
            return false
        case .mainPanel, nil:
            return true
        }
    }

    @discardableResult
    func noteMainPanelFocusIntent(
        workspaceId: UUID,
        panelId: UUID,
        source _unused: MainWindowMainPanelFocusSource
    ) -> Bool {
        guard workspaceContainsPanel(workspaceId: workspaceId, panelId: panelId) else {
            publishFeedFocusSnapshot()
            return false
        }
        noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
        return true
    }

    @discardableResult
    func noteSelectedMainPanelFocusIntent(source: MainWindowMainPanelFocusSource) -> Bool {
        guard let workspace = tabManager?.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            publishFeedFocusSnapshot()
            return false
        }
        return noteMainPanelFocusIntent(workspaceId: workspace.id, panelId: panelId, source: source)
    }

    @discardableResult
    func requestMainPanelFocus(
        workspaceId: UUID,
        panelId: UUID,
        source: MainWindowMainPanelFocusSource
    ) -> Bool {
        if TerminalSurfaceRegistry.shared.isRightSidebarDockSurface(id: panelId) {
            return true
        }

        guard acceptsMainPanelFocus(workspaceId: workspaceId, panelId: panelId, source: source) else {
#if DEBUG
            cmuxDebugLog(
                "focus.coordinator.rejectTerminalResponder " +
                    "source=\(source) workspace=\(workspaceId.uuidString.prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5))"
            )
#endif
            publishFeedFocusSnapshot()
            return false
        }

        if shouldApplyModelFocus(for: source),
           let workspace = tabManager?.selectedWorkspace,
           workspace.id == workspaceId,
           workspace.focusedPanelId != panelId {
            workspace.focusPanel(panelId, trigger: .terminalFirstResponder)
        }

#if DEBUG
        cmuxDebugLog(
            "focus.coordinator.mainPanel " +
                "source=\(source) workspace=\(workspaceId.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5))"
        )
#endif
        noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
        return true
    }

    func allowsBonsplitTabShortcutHints(workspaceId: UUID) -> Bool {
        guard tabManager?.selectedTabId == workspaceId else { return false }
        switch intent {
        case .rightSidebar:
            return false
        case .mainPanel(let focusedWorkspaceId, _):
            return focusedWorkspaceId == workspaceId
        case nil:
            return true
        }
    }

    private func acceptsMainPanelFocus(
        workspaceId: UUID,
        panelId: UUID,
        source: MainWindowMainPanelFocusSource
    ) -> Bool {
        guard let workspace = tabManager?.selectedWorkspace,
              workspace.id == workspaceId,
              workspace.panels[panelId] != nil else {
            return false
        }

        switch source {
        case .keyboardShortcut, .pointer, .programmatic:
            return true
        case .terminalFirstResponder, .responderSync:
            if hasPendingRightSidebarFocusRequest {
                return false
            }
            if case let .mainPanel(intentWorkspaceId, intentPanelId) = intent,
               intentWorkspaceId == workspaceId,
               intentPanelId == panelId {
                return true
            }
            return workspace.focusedPanelId == panelId
        }
    }

    private func shouldApplyModelFocus(for source: MainWindowMainPanelFocusSource) -> Bool {
        switch source {
        case .terminalFirstResponder, .responderSync:
            return true
        case .keyboardShortcut, .pointer, .programmatic:
            return false
        }
    }

    private func workspaceContainsPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let workspace = tabManager?.selectedWorkspace,
              workspace.id == workspaceId else {
            return false
        }
        return workspace.panels[panelId] != nil
    }
}
