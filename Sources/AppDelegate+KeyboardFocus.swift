import AppKit
import Foundation

extension AppDelegate {
    func allowsTerminalKeyboardFocus(
        workspaceId: UUID,
        panelId: UUID,
        in window: NSWindow?
    ) -> Bool {
        keyboardFocusCoordinator(for: window)?.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId) ?? true
    }

    @discardableResult
    func requestTerminalFirstResponderFocus(
        workspaceId: UUID,
        panelId: UUID,
        in window: NSWindow?
    ) -> Bool {
        keyboardFocusCoordinator(for: window)?
            .requestMainPanelFocus(workspaceId: workspaceId, panelId: panelId, source: .terminalFirstResponder) ?? false
    }

    @discardableResult
    func requestTerminalFirstResponderFocus(workspaceId: UUID, panel: any Panel) -> Bool {
        let focusWindow = (panel as? TerminalPanel)?.hostedView.window
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow
        return requestTerminalFirstResponderFocus(workspaceId: workspaceId, panelId: panel.id, in: focusWindow)
    }

    @discardableResult
    func noteFocusedMainPanelShortcutIntent(in window: NSWindow?) -> Bool {
        keyboardFocusCoordinator(for: window)?
            .noteSelectedMainPanelFocusIntent(source: .keyboardShortcut) ?? false
    }

    func syncBonsplitTabShortcutHintEligibility(in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.syncBonsplitTabShortcutHintEligibility()
    }

    struct TerminalKeyboardFocusRequest {
        let workspaceId: UUID
        let panelId: UUID
        let ghosttyView: GhosttyNSView
    }

    func terminalKeyboardFocusRequest(for responder: NSResponder?) -> TerminalKeyboardFocusRequest? {
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id else {
            return nil
        }
        if TerminalSurfaceRegistry.shared.isRightSidebarDockSurface(id: panelId) {
            return nil
        }
        return TerminalKeyboardFocusRequest(
            workspaceId: workspaceId,
            panelId: panelId,
            ghosttyView: ghosttyView
        )
    }

    func allowsTerminalKeyboardFocus(for responder: NSResponder?, in window: NSWindow?) -> Bool {
        guard let request = terminalKeyboardFocusRequest(for: responder) else {
            return true
        }
        return allowsTerminalKeyboardFocus(
            workspaceId: request.workspaceId,
            panelId: request.panelId,
            in: window
        )
    }

    func noteTerminalKeyboardFocusIntent(workspaceId: UUID, panelId: UUID, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteMainPanelFocusIntent(
            workspaceId: workspaceId,
            panelId: panelId,
            source: .pointer
        )
    }

    func noteMainPanelKeyboardFocusIntent(workspaceId: UUID, panelId: UUID, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteMainPanelFocusIntent(
            workspaceId: workspaceId,
            panelId: panelId,
            source: .programmatic
        )
    }

    func noteRightSidebarKeyboardFocusIntent(mode: RightSidebarMode, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteRightSidebarInteraction(mode: mode)
    }

    func syncKeyboardFocusAfterFirstResponderChange(in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.syncAfterResponderChange()
    }
}
