import AppKit
import CmuxNextDesign

// A one-line notice over the bottom of the page (BrowserNoticeView). The
// host decides when to show one; the chrome keeps at most one and removes it
// when the user closes it.
extension BrowserChromeView {
    /// Shows `text` in a dismissible pill at the bottom of the page,
    /// replacing any notice already shown. Child-window (Chromium) pages
    /// draw above the chrome; the pill is one of their occlusion rects, so
    /// it shows over them too.
    public func showNotice(_ text: String) {
        let notice = currentNotice ?? makeNotice()
        notice.text = text
        needsLayout = true
    }

    /// Removes the notice, if any.
    public func hideNotice() {
        guard let notice = currentNotice else { return }
        notice.isDismissing = true
        Motion.animate(.fadeOut, { notice.animator().alphaValue = 0 }, completion: { [weak self] in
            notice.removeFromSuperview()
            self?.needsLayout = true
        })
    }

    /// The notice text on screen (tests, diagnostics).
    public var noticeText: String? { currentNotice?.text }

    var currentNotice: BrowserNoticeView? {
        subviews.lazy.compactMap { $0 as? BrowserNoticeView }.first { !$0.isDismissing }
    }

    private func makeNotice() -> BrowserNoticeView {
        let notice = BrowserNoticeView()
        notice.onClose = { [weak self] in self?.hideNotice() }
        addSubview(notice)
        let inset = BrowserMetrics.overlayInset
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            notice.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: inset),
        ])
        notice.alphaValue = 0
        Motion.animate(.fadeIn) { notice.animator().alphaValue = 1 }
        return notice
    }
}
