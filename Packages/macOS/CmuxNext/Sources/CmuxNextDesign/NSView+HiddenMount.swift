public import AppKit

extension NSView {
    /// Pre-renders `view` at this view's size outside the window. Hidden web renderers cannot draw a resized frame.
    /// Showing it later changes only its origin and alpha, with no window entry or visible resize.
    public func addPrewarmedSubview(_ view: NSView) {
        view.alphaValue = 0
        view.frame = bounds.offsetBy(dx: -100_000, dy: -100_000)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        view.layoutSubtreeIfNeeded()
    }
}
