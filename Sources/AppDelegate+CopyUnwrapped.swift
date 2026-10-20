import AppKit

extension AppDelegate {
    func handleCopyUnwrappedShortcut(_ event: NSEvent) -> Bool {
        guard matchConfiguredShortcut(event: event, action: .copyUnwrapped) else { return false }
        let window = resolvedShortcutEventWindow(event) ?? event.window ?? NSApp.keyWindow
        guard let terminal = window?.firstResponder.cmuxTerminalFocusOwningGhosttyView() else { return false }
        terminal.copyUnwrapped(nil)
        return true
    }
}
