import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Find & Focused Terminal Actions
extension TabManager {
    var isFindVisible: Bool {
        selectedTerminalPanel?.searchState != nil || focusedBrowserPanel?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedTerminalPanel?.hasSelection() == true
    }

    @discardableResult
    func startSearch() -> Bool {
        if let panel = selectedTerminalPanel {
            let hadExistingSearch = panel.searchState != nil
            panel.hostedView.preparePanelFocusIntentForActivation(.findField)
            let recoveredNeedle = hadExistingSearch ? "" : panel.surface.lastSearchNeedle
            let handled = startOrFocusTerminalSearch(panel.surface, initialNeedle: recoveredNeedle) { surface in
                NotificationCenter.default.post(
                    name: .ghosttySearchFocus,
                    object: surface,
                    userInfo: [FindFocusNotificationKey.selectAll: !hadExistingSearch && !recoveredNeedle.isEmpty]
                )
            }
#if DEBUG
            cmuxDebugLog(
                "find.startSearch workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
                "panel=\(panel.id.uuidString.prefix(5)) existing=\(hadExistingSearch ? "yes" : "no") " +
                "handled=\(handled ? 1 : 0) " +
                "firstResponder=\(String(describing: panel.surface.uiWindow?.firstResponder))"
            )
#endif
            return handled
        }
        guard let browserPanel = focusedBrowserPanel else { return false }
        browserPanel.startFind()
        return browserPanel.searchState != nil
    }

    func searchSelection() {
        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
#if DEBUG
        cmuxDebugLog(
            "find.searchSelection workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
            "panel=\(panel.id.uuidString.prefix(5))"
        )
#endif
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("search_selection")
    }

    func findNext() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:next")
            return
        }

        focusedBrowserPanel?.findNext()
    }

    func findPrevious() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:previous")
            return
        }

        focusedBrowserPanel?.findPrevious()
    }

    @discardableResult
    func toggleFocusedTerminalCopyMode() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.surface.toggleKeyboardCopyMode()
    }

    /// Forwards a single Ctrl-F (`^F`) key press to the focused terminal surface,
    /// faithfully encoded through Ghostty so it matches whatever the running TUI
    /// would receive from a real keystroke.
    ///
    /// This is the non-keyboard escape hatch for control chords that a focused TUI
    /// reads off the raw tty. The motivating case is Claude Code's force-stop, which
    /// is only exposed as "press Ctrl-F twice"; invoke this action twice to deliver
    /// it. Delivery bypasses cmux's shortcut/menu/responder layers entirely.
    ///
    /// - Returns: `true` when the chord was sent or queued for the focused terminal,
    ///   `false` when no terminal panel is focused.
    @discardableResult
    func sendCtrlFToFocusedTerminal() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        let result = panel.sendNamedKeyResult("ctrl-f")
        if result == .sent {
            panel.surface.forceRefresh(reason: "tabManager.sendCtrlFToFocusedTerminal")
        }
#if DEBUG
        cmuxDebugLog(
            "terminal.sendCtrlF workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
            "panel=\(panel.id.uuidString.prefix(5)) result=\(result)"
        )
#endif
        return result.accepted
    }

    @discardableResult
    func toggleFocusedTerminalTextBox() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.toggleTextBoxInput()
    }

    @discardableResult
    func focusFocusedTerminalTextBoxInputOrTerminal() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.focusTextBoxInputOrTerminal()
    }

    @discardableResult
    func attachFileToFocusedTerminalTextBoxInput() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.attachFileToTextBoxInput()
    }

    @discardableResult
    func consumeFocusedTerminalTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool {
        guard let focusedPanel = selectedTerminalPanel else {
            clearFocusedTerminalTextBoxHideEscapeArm()
            return false
        }
        let consumed = focusedPanel.consumeTextBoxHideEscapeIfArmed(in: window)
        guard !consumed else { return true }
        for panel in selectedWorkspaceTerminalPanels {
            if panel === focusedPanel { continue }
            panel.clearTextBoxHideEscapeArm()
        }
        return false
    }

    func clearFocusedTerminalTextBoxHideEscapeArm() {
        for panel in selectedWorkspaceTerminalPanels {
            panel.clearTextBoxHideEscapeArm()
        }
    }

    func hideFind() {
        if let panel = selectedTerminalPanel {
            panel.searchState = nil
            return
        }

        focusedBrowserPanel?.hideFind()
    }

}
