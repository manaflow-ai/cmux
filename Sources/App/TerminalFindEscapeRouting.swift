import AppKit
import CmuxTerminal

@MainActor
func cmuxCloseFocusedTerminalFindForEscape(event: NSEvent, appDelegate: AppDelegate) -> Bool {
    guard cmuxFindEventIsPlainEscape(event) else { return false }

    let shortcutWindow = event.window
        ?? (event.windowNumber > 0 ? NSApp.window(withWindowNumber: event.windowNumber) : nil)
        ?? NSApp.keyWindow
        ?? NSApp.mainWindow
    if shortcutWindow?.firstResponder is TextBoxInputTextView {
        return false
    }
    let terminalFindField = cmuxFindTextFieldOwner(for: shortcutWindow?.firstResponder)
        .flatMap { $0.identifier?.rawValue == "TerminalFindSearchTextField" ? $0 : nil }
    let targetTabManager = appDelegate.synchronizeActiveMainWindowContext(preferredWindow: shortcutWindow)

    guard let panel = (targetTabManager ?? appDelegate.tabManager)?.selectedTerminalPanel,
          panel.searchState != nil,
          // A find field outside this panel (another window's terminal) closes its own find.
          terminalFindField.map({ $0.isDescendant(of: panel.hostedView) }) ?? true,
          !shortcutResponderHasMarkedText(shortcutWindow?.firstResponder),
          terminalFindField != nil || appDelegate.allowsTerminalKeyboardFocus(
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
