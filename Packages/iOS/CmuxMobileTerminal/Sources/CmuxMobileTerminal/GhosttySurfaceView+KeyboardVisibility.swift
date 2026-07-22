#if os(iOS)
import Foundation
import UIKit

extension GhosttySurfaceView {
    func observeKeyboardVisibilityReconciliation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardDidShow(_:)),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardDidHide(_:)),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
    }

    @objc
    func handleKeyboardDidShow(_ notification: Notification) {
        reconcileKeyboardVisibilityFromSystem(true)
    }

    @objc
    func handleKeyboardDidHide(_ notification: Notification) {
        reconcileKeyboardVisibilityFromSystem(false)
    }

    func reconcileKeyboardVisibilityFromSystem(_ isVisible: Bool) {
        // A responder handoff (terminal proxy -> composer field, or back) can
        // emit a late `didHide` for the outgoing responder after the replacement
        // already owns the live keyboard. The local first-responder tree is the
        // authoritative tie-breaker; otherwise that stale notification relabels
        // the still-visible toggle as "Show Keyboard".
        let effectiveVisibility = isVisible || hasLocalKeyboardFirstResponder
        keyboardVisible = effectiveVisibility
        inputProxy.setKeyboardShown(effectiveVisibility)
    }
}
#endif
