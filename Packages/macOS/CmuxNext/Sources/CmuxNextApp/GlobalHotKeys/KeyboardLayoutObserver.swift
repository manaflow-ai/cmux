import AppKit
import Carbon.HIToolbox

/// Calls `onChange` when the selected keyboard layout changes, also while
/// cmux is in the background. Distributed notifications are otherwise held
/// until the app is active again, which is too late for a system-wide key.
final class KeyboardLayoutObserver: NSObject {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(layoutChanged(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func layoutChanged(_ notification: Notification) {
        onChange()
    }
}
