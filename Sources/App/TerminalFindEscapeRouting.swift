import AppKit
import CmuxTerminal

@MainActor
func cmuxCloseFocusedTerminalFindForEscape(event: NSEvent, appDelegate: AppDelegate) -> Bool {
    guard cmuxFindEventIsPlainEscape(event) else { return false }

    // An armed prefix owns Escape as its cancel gesture. Let the app-level
    // shortcut monitor consume it before the terminal find overlay can close
    // itself (the monitor calls this helper immediately before dispatch).
    guard !appDelegate.shortcutPrefixChordCoordinator.isArmed else { return false }

    let shortcutWindow = event.window
        ?? (event.windowNumber > 0 ? NSApp.window(withWindowNumber: event.windowNumber) : nil)
        ?? NSApp.keyWindow
        ?? NSApp.mainWindow
    if shortcutWindow?.firstResponder is TextBoxInputTextView {
        return false
    }
    let terminalFindFieldOwnsResponder = cmuxFindTextFieldOwner(for: shortcutWindow?.firstResponder)?
        .identifier?.rawValue == "TerminalFindSearchTextField"
    let targetTabManager = appDelegate.synchronizeActiveMainWindowContext(preferredWindow: shortcutWindow)

    guard let panel = (targetTabManager ?? appDelegate.tabManager)?.selectedTerminalPanel,
          panel.searchState != nil,
          !shortcutResponderHasMarkedText(shortcutWindow?.firstResponder),
          terminalFindFieldOwnsResponder || appDelegate.allowsTerminalKeyboardFocus(
              workspaceId: panel.workspaceId,
              panelId: panel.id,
              in: shortcutWindow
          ) else {
        return false
    }

#if DEBUG
    cmuxDebugLog("find.escape.close terminal panel=\(panel.id.uuidString.prefix(5))")
#endif
    panel.hostedView.beginFindEscapeSuppression()
    panel.surface.closeSearchFromExplicitInput()
    panel.hostedView.moveFocus()
    return true
}
