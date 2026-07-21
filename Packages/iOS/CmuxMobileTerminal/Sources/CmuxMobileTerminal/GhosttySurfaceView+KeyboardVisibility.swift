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
        keyboardVisible = isVisible
        inputProxy.setKeyboardShown(isVisible)
    }
}
#endif
