import AppKit
import CmuxNextFocusUI

extension CrossWindowInputGuard {
    /// The guard over the app's cmux windows: a window belongs to the one that owns it (`WindowManager.owner(of:)`).
    init(windows: WindowManager) {
        self.init { [weak windows] window in windows?.owner(of: window)?.state.id }
    }
}
