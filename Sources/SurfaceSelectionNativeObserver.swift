import AppKit

/// A text-view-scoped selection observer. It never installs an app-wide
/// observer, so replacing or moving one editor cannot notify another surface.
@MainActor
final class SurfaceSelectionNativeObserver {
    private weak var textView: NSTextView?
    private var notificationToken: NSObjectProtocol?
    private let onChange: () -> Void

    init(textView: NSTextView, onChange: @escaping () -> Void) {
        self.textView = textView
        self.onChange = onChange
        notificationToken = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let textView = self.textView,
                      notification.object as AnyObject? === textView else { return }
                self.onChange()
            }
        }
    }

    func stop() {
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
            self.notificationToken = nil
        }
        textView = nil
    }

    deinit {
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
        }
    }
}
