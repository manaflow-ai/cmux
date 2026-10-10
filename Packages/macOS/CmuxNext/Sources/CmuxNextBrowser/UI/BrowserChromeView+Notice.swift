import AppKit
import CmuxNextDesign

// A one-line notice over the bottom of the page (BrowserNoticeView). The
// host decides when to show one; the chrome keeps at most one and removes it
// when the user closes it.
extension BrowserChromeView {
    /// Shows `text` in a dismissible pill at the bottom of the page,
    /// replacing any notice already shown. It floats on the window's overlay
    /// host (`PageFloatingOverlays`), so it shows above Chromium pages too.
    public func showNotice(_ text: String) {
        showNotice(text, action: nil)
    }

    /// Shows `text` with one action button (`title`, `run`), or none.
    public func showNotice(_ text: String, action: (title: String, run: () -> Void)?) {
        let notice = currentNotice ?? makeNotice()
        notice.text = text
        notice.action = action
        syncPageOverlays()
    }

    /// The notice's action title on screen (tests, diagnostics).
    public var noticeActionTitle: String? { currentNotice?.action?.title }

    /// Removes the notice, if any.
    public func hideNotice() {
        guard let notice = currentNotice else { return }
        notice.isDismissing = true
        Motion.animate(.fadeOut, in: notice, { notice.animator().alphaValue = 0 }, completion: { [weak self] in
            self?.pageOverlays.remove(notice)
        })
    }

    /// The notice text on screen (tests, diagnostics).
    public var noticeText: String? { currentNotice?.text }

    /// The notice's view tree with each frame and any label text (diagnostics).
    public var noticeLayout: [String]? { currentNotice?.layoutReport }

    /// Where the notice draws (diagnostics): `overlay_host` (above pages),
    /// `window` (under a Chromium page), `offscreen` (parked), nil: none.
    public var noticePlacement: String? {
        currentNotice.map { $0.window is OverlayHostPanel ? "overlay_host" : $0.window == nil ? "offscreen" : "window" }
    }

    /// Whether a click at the notice's center goes to the overlay host
    /// (diagnostics); nil when no notice is presented.
    public var noticeTakesMouse: Bool? { (pageOverlays.views.last { $0 is BrowserNoticeView }).flatMap(pageOverlays.takesMouse) }

    var currentNotice: BrowserNoticeView? {
        pageOverlays.views.lazy.compactMap { $0 as? BrowserNoticeView }.first { !$0.isDismissing }
    }

    private func makeNotice() -> BrowserNoticeView {
        let notice = BrowserNoticeView()
        notice.onClose = { [weak self] in self?.hideNotice() }
        pageOverlays.add(notice)
        notice.alphaValue = 0
        syncPageOverlays()
        Motion.animate(.fadeIn, in: notice) { notice.animator().alphaValue = 1 }
        return notice
    }

    /// Places the floating page cards over the page area (or takes them
    /// off screen while this chrome is out of a window or hidden).
    func syncPageOverlays() {
        pageOverlays.sync()
    }
}
