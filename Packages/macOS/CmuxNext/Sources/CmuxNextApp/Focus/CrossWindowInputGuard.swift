import AppKit
import CmuxNextDesign
import CmuxNextFocusUI

extension CrossWindowInputGuard {
    /// `CmuxApplication.crossWindowKeyGuard`: the guard over `router`'s cmux windows (`WindowManager.owner(of:)`).
    static func drops(keyTypedInto eventWindow: NSWindow?, keyWindow: NSWindow?, router: KeyRouter?) -> Bool {
        guard let router, let windows = router.services?.windows, !router.newTabInputCoordinator.followsNewWindow else { return false } // New Window's keys follow it
        let keyGuard = CrossWindowInputGuard { [weak windows] in windows?.owner(of: $0)?.state.id }
        // In-tree pages retire only a key that involves a Chromium page window (none should exist; counted in `debug.focus`
        // `in_tree_guards`); a key crossing real cmux windows (several windows, a `window.open` popup) is judged as off.
        if InTreePages.shared.isActive, eventWindow?.isChromiumPageWindow == true || keyWindow?.isChromiumPageWindow == true {
            if keyGuard.dropsKey(eventWindow: eventWindow, keyWindow: keyWindow, heldRun: router.creationInputCoordinator.replaying?.run) {
                InTreeRetiredGuards.shared.fired(.crossWindowInput)
            }
            return false
        }
        return keyGuard.dropsAndLogsKey(eventWindow: eventWindow, keyWindow: keyWindow, heldRun: router.creationInputCoordinator.replaying?.run)
    }
}
