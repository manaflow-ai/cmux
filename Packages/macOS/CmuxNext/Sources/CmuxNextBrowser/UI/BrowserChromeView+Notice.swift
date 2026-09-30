import AppKit

// A one-line notice over the bottom of the page (BrowserNoticeView). The
// host decides when to show one; the chrome keeps at most one and removes it
// when the user closes it.
extension BrowserChromeView {
    /// Shows `text` in a dismissible pill at the bottom of the page,
    /// replacing any notice already shown. Child-window (Chromium) pages
    /// draw above the chrome, so this is for in-view (WebKit) pages.
    public func showNotice(_ text: String) {
        let notice = currentNotice ?? makeNotice()
        notice.text = text
    }

    /// Removes the notice, if any.
    public func hideNotice() {
        guard let notice = currentNotice else { return }
        notice.isDismissing = true
        Motion.animate(duration: 0.12, { notice.animator().alphaValue = 0 }) {
            notice.removeFromSuperview()
        }
    }

    /// The notice text on screen (tests, diagnostics).
    public var noticeText: String? { currentNotice?.text }

    private var currentNotice: BrowserNoticeView? {
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
        Motion.animate(duration: 0.14) { notice.animator().alphaValue = 1 }
        return notice
    }
}
