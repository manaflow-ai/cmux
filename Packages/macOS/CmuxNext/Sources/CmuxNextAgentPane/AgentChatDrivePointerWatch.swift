import AppKit

/// The person's real pointer in a pane whose `agent.chat.drive` release is still pending: a tracking
/// area on the pane (installed for the release, removed once it went in) that ends it
/// (``DriveRelease/personPointer()``). AppKit makes tracking-area events from the real cursor only; the
/// run's own moves and its pointer-leave are handed to the web view itself (``AgentChatDriveInput``)
/// and never reach this area, so they never count. It covers both hosts (the page host's view and the
/// pane's own WebKit view are the pane's subviews), and Chromium's page while it shows in the pane's
/// window, not over it in its own child window.
@MainActor
final class DrivePointerWatch: NSObject {
    private weak var release: DriveRelease?
    private weak var view: NSView?
    private var area: NSTrackingArea?

    /// The watch for `release`, which holds it until a release went in.
    init(release: DriveRelease) {
        self.release = release
        super.init()
        release.pointerWatch = self
    }

    /// Watches `view`'s visible rect, in an active window or not (as WebKit's own hover does).
    func install(on view: NSView) {
        remove()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        view.addTrackingArea(area)
        self.view = view
        self.area = area
    }

    func remove() {
        if let area { view?.removeTrackingArea(area) }
        area = nil
        view = nil
    }

    // A tracking area's owner need not be a responder: AppKit sends it these by selector.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { release?.personPointer() }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { release?.personPointer() }
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) { release?.personPointer() }
}
