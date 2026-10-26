public import AppKit

// A host-supplied bar between the toolbar and the page (the bookmarks bar,
// plans/cmux-next/bookmarks.md section 3). It belongs to the pane header:
// the page area, its border and rounded corners start below it, and it hides
// with the toolbar while page content is fullscreen. The chrome places it by
// frame (`BrowserChromeLayout`).
extension BrowserChromeView {
    /// The view shown under the toolbar, or nil for none. `height` is its
    /// height in points (the bar's own metric).
    public func setAccessoryView(_ view: NSView?, height: CGFloat) {
        let current = accessoryBar.subviews.first
        if current !== view {
            current?.removeFromSuperview()
            if let view {
                // The view fills the bar and follows its size (frame layout, no constraints).
                view.translatesAutoresizingMaskIntoConstraints = true
                view.autoresizingMask = [.width, .height]
                view.frame = accessoryBar.bounds
                accessoryBar.addSubview(view)
            }
        }
        accessoryHeight = view == nil ? 0 : height
        applyAccessoryHeight()
        syncHeaderBand(animated: false)
    }

    /// Zero while page content is fullscreen (the toolbar is hidden too).
    func applyAccessoryHeight() {
        let height = accessoryBar.isHidden ? 0 : accessoryHeight
        guard height != shownAccessoryHeight else { return }
        shownAccessoryHeight = height
        needsLayout = true
    }

    /// The view under the toolbar, if any.
    public var accessoryView: NSView? { accessoryBar.subviews.first }

    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let view = responder as? NSView { return view.isDescendant(of: self) }
        if let editor = responder as? NSText, let delegate = editor.delegate as? NSView {
            return delegate.isDescendant(of: self)
        }
        return false
    }
}
