import AppKit
import CmuxNextDesign
import CmuxNextFocusUI

extension CrossWindowInputGuard {
    /// `CmuxApplication.crossWindowKeyGuard`: the guard over `router`'s cmux windows (`WindowManager.owner(of:)`).
    static func drops(keyTypedInto eventWindow: NSWindow?, keyWindow: NSWindow?, router: KeyRouter?) -> Bool {
        guard let router, let windows = router.services?.windows, !router.newTabInputCoordinator.followsNewWindow else { return false } // New Window's keys follow it
        let keyGuard = CrossWindowInputGuard { [weak windows] in windows?.owner(of: $0)?.state.id }
        let heldRun = router.creationInputCoordinator.replaying?.run
        // In-tree pages: a page is a view of its cmux window, never a window, so the page-window case (a key between a
        // cmux window and a Chromium page window) is gone; a key that still involves a page window is delivered and
        // counted (`debug.focus` `in_tree_guards`, which must stay 0). Separate cmux windows (several windows, a
        // `window.open` popup's own window) and floating panels still exist: a key crossing between them is judged as
        // with the mode off.
        if InTreePages.shared.isActive, eventWindow?.isChromiumPageWindow == true || keyWindow?.isChromiumPageWindow == true {
            if keyGuard.dropsKey(eventWindow: eventWindow, keyWindow: keyWindow, heldRun: heldRun) {
                InTreeRetiredGuards.shared.fired(.crossWindowInput)
            }
            return false
        }
        return keyGuard.dropsAndLogsKey(eventWindow: eventWindow, keyWindow: keyWindow, heldRun: heldRun)
    }
}
