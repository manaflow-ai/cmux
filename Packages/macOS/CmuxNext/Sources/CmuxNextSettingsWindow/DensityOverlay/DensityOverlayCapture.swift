import AppKit
import CmuxNextDesign

/// The Density Overlay Playground's live image: the top chrome of the first browser pane (a tab strip whose omnibar
/// meets its tabs, ``TabStripCorner/meetsToolbar``) in the app's front main window, from the pane's leading edge and
/// the window's top, as the window server composited it (``NSWindow/compositedSnapshot(includeChild:)``, no Screen
/// Recording grant). The reference captures are cropped the same way: the browser window's left edge and top.
@MainActor struct DensityOverlayCapture {
    /// The window the chrome is read from: the main window, else the frontmost titled window that is not a panel.
    let window: NSWindow

    /// The app's window that draws the chrome, if one is open.
    init?(app: NSApplication = .shared) {
        let candidates = ([app.mainWindow] + app.orderedWindows).compactMap { $0 }
        guard let window = candidates.first(where: { !($0 is NSPanel) && $0.isVisible && Self.browserStrip(in: $0) != nil })
        else { return nil }
        self.window = window
    }

    /// The first browser pane's strip in `window`, leftmost then topmost.
    static func browserStrip(in window: NSWindow) -> (any TabStripCorner & NSView)? {
        guard let root = window.contentView else { return nil }
        var found: [any TabStripCorner & NSView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let strip = view as? any TabStripCorner & NSView, strip.meetsToolbar, !strip.isHiddenOrHasHiddenAncestor {
                found.append(strip)
            }
            stack.append(contentsOf: view.subviews)
        }
        return found.min { a, b in
            let fa = a.cornerFrameInWindow, fb = b.cornerFrameInWindow
            return fa.minX != fb.minX ? fa.minX < fb.minX : fa.maxY > fb.maxY
        }
    }

    /// The pane's top chrome in window coordinates: from its leading edge, the pane's top (and the padding over it) down through the gap,
    /// the tab row, the gap, the omnibar row and the gap under it (``Metrics/browserRowGap``), the pane's width.
    func chromeRect() -> CGRect? {
        guard let strip = Self.browserStrip(in: window), let pane = strip.superview else { return nil }
        let frame = pane.convert(pane.bounds, to: nil)
        let gap = Metrics.browserRowGap ?? PaneChromeMetrics.current.tabGap(scale: window.backingScaleFactor)
        let height = 3 * gap + 2 * Metrics.tabHeight
        // The strip's pane starts at the window's top under the flush corner (its gap above the pills is the strip's).
        let top = min(frame.maxY + Metrics.stripTopOutset, window.frame.height)
        return CGRect(x: frame.minX, y: top - height, width: frame.width, height: height)
    }

    /// The chrome as pixels, `maxWidth` points wide at most (the reference's width), or nil when the window gives none.
    func image(maxWidth: CGFloat? = nil) -> CGImage? {
        // perf-gate-ok: a debug tool; it captures only while the person has the Density Overlay Playground open
        guard var rect = chromeRect(), let shot = window.compositedSnapshot() else { return nil }
        if let maxWidth { rect.size.width = min(rect.width, maxWidth) }
        let scale = CGFloat(shot.width) / max(window.frame.width, 1)
        // The snapshot's origin is the window's top left; window coordinates start at its bottom left.
        let crop = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                          width: rect.width * scale, height: rect.height * scale).integral
        return shot.cropping(to: crop)
    }
}
