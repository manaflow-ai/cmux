import AppKit
import Carbon.HIToolbox

/// Calls `onChange` when the selected keyboard layout changes, also while
/// cmux is in the background. Distributed notifications are otherwise held
/// until the app is active again, which is too late for a system-wide key.
final class KeyboardLayoutObserver: NSObject {
    private let onChange: () -> Void
    private var observer: NSObjectProtocol?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] notification in
            // main-proof: DistributedNotificationCenter delivers this block on the main operation queue.
            MainActor.assumeIsolated { self?.layoutChanged(notification) }
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func layoutChanged(_ notification: Notification) {
        onChange()
    }
}
