import AppKit
import CmuxNextDesign
import CmuxNextFocusUI

extension CrossWindowInputGuard {
    /// `CmuxApplication.crossWindowKeyGuard`: the guard over `router`'s cmux windows (`WindowManager.owner(of:)`).
    static func drops(keyTypedInto eventWindow: NSWindow?, keyWindow: NSWindow?, router: KeyRouter?) -> Bool {
        guard let router, let windows = router.services?.windows, !router.newTabInputCoordinator.followsNewWindow else { return false } // New Window's keys follow it
        let keyGuard = CrossWindowInputGuard { [weak windows] in windows?.owner(of: $0)?.state.id }
        // In-tree pages: the cmux window is always key and no page is a window, so the guard is bypassed; a key it
        // would have dropped is counted (`debug.focus` `in_tree_guards`, which must stay 0).
        if InTreePages.shared.isActive {
            if keyGuard.dropsKey(eventWindow: eventWindow, keyWindow: keyWindow, heldRun: router.creationInputCoordinator.replaying?.run) {
                InTreeRetiredGuards.shared.fired(.crossWindowInput)
            }
            return false
        }
        return keyGuard.dropsAndLogsKey(eventWindow: eventWindow, keyWindow: keyWindow, heldRun: router.creationInputCoordinator.replaying?.run)
    }
}
