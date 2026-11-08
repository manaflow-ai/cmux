import AppKit

/// The chrome's page area (`BrowserChromeView.contentContainer`): the shown tab's page fills it. With one chrome per
/// pane (#32909 step B) a tab switch keeps the leaving page there, hidden (`parks`), so the way back moves no window
/// (a Chromium page conceals itself when hidden); a page another pane's chrome took meanwhile is not touched.
@MainActor
struct BrowserPageArea {
    let container: NSView

    /// `page` stops showing: hidden in place when it `parks`, else out of the area.
    func leave(_ page: NSView, parks: Bool) {
        guard page.superview === container else { return }
        if parks { page.isHidden = true } else { page.removeFromSuperview() }
    }

    /// `page` shows, filling the area: unhidden when it is parked here, else added.
    func show(_ page: NSView) {
        page.isHidden = false
        guard page.superview !== container else { return }
        page.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
