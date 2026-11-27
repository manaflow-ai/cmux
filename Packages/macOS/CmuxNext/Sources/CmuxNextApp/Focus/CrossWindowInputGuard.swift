import AppKit
import CmuxNextFocusUI

extension CrossWindowInputGuard {
    /// `CmuxApplication.crossWindowKeyGuard`: the guard over `router`'s cmux windows (`WindowManager.owner(of:)`).
    static func drops(keyTypedInto eventWindow: NSWindow?, keyWindow: NSWindow?, router: KeyRouter?) -> Bool {
        guard let router, let windows = router.services?.windows, !router.newTabInputCoordinator.followsNewWindow else { return false } // New Window's keys follow it
        let keyGuard = CrossWindowInputGuard { [weak windows] in windows?.owner(of: $0)?.state.id }
        return keyGuard.dropsAndLogsKey(eventWindow: eventWindow, keyWindow: keyWindow, heldRun: router.creationInputCoordinator.replaying?.run)
    }
}
