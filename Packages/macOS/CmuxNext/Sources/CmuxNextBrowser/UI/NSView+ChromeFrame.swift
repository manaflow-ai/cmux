import AppKit

// Frame layout helpers for the browser chrome (`ChromeFrameMapping`).
extension NSView {
    /// Maps top-down, leading-first rects into this view's coordinates.
    var chromeFrameMapping: ChromeFrameMapping {
        ChromeFrameMapping(size: bounds.size, isFlipped: isFlipped, rightToLeft: userInterfaceLayoutDirection == .rightToLeft)
    }

    /// Places this view so its alignment rect is `rect`, as a constraint
    /// placed it (an NSButton's frame can carry bezel insets). An unchanged
    /// frame is not set again; a new size lays the view out again, as a
    /// constraint-driven size did.
    func setChromeFrame(_ rect: CGRect) {
        let frame = frame(forAlignmentRect: rect)
        guard self.frame != frame else { return }
        let resized = self.frame.size != frame.size
        self.frame = frame
        if resized { needsLayout = true }
    }
}
