import AppKit
import CmuxNextWakeups

/// The hibernation picture a woken page shows over itself until it draws its document
/// (`BrowserChromeView.holdPicture(whileWaking:)`).
@MainActor
final class WakePictureCover {
    /// How long the picture stays once the woken document committed: WebKit reports no first
    /// paint, and paints a committed document within a few frames (as `WebKitTab.pageBaseHoldLimit`).
    static let limitAfterCommit: Duration = .milliseconds(400)
    /// The longest the picture stays over a page that does not commit (a slow or dead network):
    /// the page's own loading state shows after it.
    static let limit: Duration = .seconds(2)

    private(set) var view: NSView?
    private var committed = false
    // Justified deadline, not a poll: a page that never reports its load end still shows itself.
    private lazy var deadline = DemandTimer(owner: "browser.wakePicture")

    func begin(_ picture: CGImage, over page: NSView, in container: NSView) {
        end()
        let cover = PictureView(frame: container.bounds)
        cover.image = NSImage(cgImage: picture, size: .zero)
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        if page.superview === container {
            container.addSubview(cover, positioned: .above, relativeTo: page)
        } else {
            container.addSubview(cover)
        }
        view = cover
        committed = false
        deadline.schedule(after: Self.limit) { @MainActor [weak self] in self?.end() }
    }

    /// The woken page's state changed: the picture goes once the page drew or cannot.
    func follow(_ state: BrowserTabState) {
        guard view != nil else { return }
        if state.hasEndedLoad || state.processExit != nil || state.loadError != nil { return end() }
        if state.phase == .committed, !committed {
            committed = true
            deadline.schedule(after: Self.limitAfterCommit) { @MainActor [weak self] in self?.end() }
        }
    }

    func end() {
        deadline.cancel()
        view?.removeFromSuperview()
        view = nil
    }
}

/// A picture that lets every click and scroll through to the page under it.
private final class PictureView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
