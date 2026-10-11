public import AppKit

// A host-supplied bar between the toolbar and the page (the bookmarks bar,
// plans/cmux-next/bookmarks.md section 3). It belongs to the pane header:
// the page area, its border and rounded corners start below it, and it hides
// with the toolbar while page content is fullscreen.
extension BrowserChromeView {
    private static let heightIdentifier = "cmux.browser.accessoryBar.height"

    func installAccessoryBar(below separator: NSView) {
        addSubview(accessoryBar)
        let height = accessoryBar.heightAnchor.constraint(equalToConstant: 0)
        height.identifier = Self.heightIdentifier
        NSLayoutConstraint.activate([
            accessoryBar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            accessoryBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accessoryBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
        ])
    }

    /// The view shown under the toolbar, or nil for none. `height` is its
    /// height in points (the bar's own metric).
    public func setAccessoryView(_ view: NSView?, height: CGFloat) {
        let current = accessoryBar.subviews.first
        if current !== view {
            current?.removeFromSuperview()
            if let view {
                view.translatesAutoresizingMaskIntoConstraints = false
                accessoryBar.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: accessoryBar.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: accessoryBar.trailingAnchor),
                    view.topAnchor.constraint(equalTo: accessoryBar.topAnchor),
                    view.bottomAnchor.constraint(equalTo: accessoryBar.bottomAnchor),
                ])
            }
        }
        accessoryHeight = view == nil ? 0 : height
        applyAccessoryHeight()
    }

    /// Zero while page content is fullscreen (the toolbar is hidden too).
    func applyAccessoryHeight() {
        let constant = accessoryBar.isHidden ? 0 : accessoryHeight
        guard let constraint = accessoryBar.constraints.first(where: { $0.identifier == Self.heightIdentifier }),
              constraint.constant != constant else { return }
        constraint.constant = constant
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
