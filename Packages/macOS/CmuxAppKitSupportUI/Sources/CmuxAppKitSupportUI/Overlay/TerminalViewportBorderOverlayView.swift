public import AppKit

/// Strokes the iOS-connected viewport border on the right and/or bottom edge of
/// the effective Mac terminal grid. It never becomes first responder and never
/// hit-tests, so it overlays terminal content without intercepting events.
///
/// The stroke color matches every other window-chrome separator in the app. The
/// chrome background that color is derived from is resolved app-side, so the app
/// injects it through ``chromeBackgroundColorProvider`` rather than this package
/// depending on the app's background-theme type.
public final class TerminalViewportBorderOverlayView: NSView {
    /// The effective size of the Mac terminal grid the border is stroked around.
    public var effectiveSize: CGSize? {
        didSet { needsDisplay = true }
    }

    /// Whether any viewport border edge should be stroked.
    public var drawsVisibleAreaBorder = false {
        didSet { needsDisplay = true }
    }
    /// Whether the right edge of the viewport border should be stroked.
    public var drawsVisibleAreaRightBorder = false {
        didSet { needsDisplay = true }
    }
    /// Whether the bottom edge of the viewport border should be stroked.
    public var drawsVisibleAreaBottomBorder = false {
        didSet { needsDisplay = true }
    }

    /// Resolves the window-chrome background color the separator stroke is
    /// derived from. Injected by the app (which owns the background theme) so
    /// this view stays decoupled from app-side chrome state. The app sets this
    /// before the border is ever drawn; the default resolves to clear.
    public var chromeBackgroundColorProvider: @MainActor () -> NSColor = { .clear }

    public override var acceptsFirstResponder: Bool { false }
    public override var isFlipped: Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsVisibleAreaBorder,
              let effectiveSize,
              effectiveSize.width > 1,
              effectiveSize.height > 1 else {
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / max(1, scale)
        let width = min(effectiveSize.width, bounds.width)
        let height = min(effectiveSize.height, bounds.height)
        guard width > lineWidth, height > lineWidth else { return }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        let x = width - lineWidth / 2
        let y = height - lineWidth / 2
        if drawsVisibleAreaRightBorder {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: y))
        }
        if drawsVisibleAreaBottomBorder {
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: x, y: y))
        }
        // Stroke the exact window-chrome separator color used by the pane outline,
        // sidebar trailing edge, and tab-bar separators (one source of truth), so the
        // iOS-connected viewport border is pixel-identical to every other border in the
        // app instead of the previous hardcoded near-white separator stroke.
        WindowChromeColorResolver()
            .separatorColor(forChromeBackground: chromeBackgroundColorProvider())
            .setStroke()
        path.stroke()
    }
}
