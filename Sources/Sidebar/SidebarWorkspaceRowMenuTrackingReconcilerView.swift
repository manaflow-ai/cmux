import AppKit

final class SidebarWorkspaceRowMenuTrackingReconcilerView: NSView {
    var onMenuTrackingEnded: ((Bool) -> Void)?
    private var menuEndObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshMenuTrackingObserver()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
        }
    }

    private func refreshMenuTrackingObserver() {
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
            self.menuEndObserver = nil
        }
        guard window != nil else { return }
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onMenuTrackingEnded?(self.isPointerInsideBounds())
        }
    }

    private func isPointerInsideBounds() -> Bool {
        guard let window else { return false }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = convert(pointInWindow, from: nil)
        return bounds.contains(pointInView)
    }
}
