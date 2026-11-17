import AppKit

extension AppDelegate {
    /// Focus Pane 1…9 (unbound by default) focuses a split pane by its tree-order number (9 = last).
    /// A matched digit is always consumed so an out-of-range pane number never
    /// falls through to Ghostty.
    func handlePaneNumberShortcut(_ event: NSEvent) -> Bool {
        guard let digit = routableNumberedConfiguredShortcutDigit(event: event, action: .focusPaneByNumber) else {
            return false
        }
        tabManagerForNumberedShortcut(event: event)?.focusPane(number: digit)
        return true
    }
}

@MainActor
extension TabManager {
    /// Focus pane 1…9 of the selected workspace in tree order (9 = last).
    @discardableResult
    func focusPane(number: Int) -> Bool {
        selectedWorkspace?.focusPane(number: number) ?? false
    }
}
