import AppKit

/// The screen edge from which the Quick Terminal slides in.
enum QuickTerminalPosition: String {
    /// Slide in from the top edge of the screen.
    case top
    /// Slide in from the bottom edge of the screen.
    case bottom
    /// Slide in from the left edge of the screen.
    case left
    /// Slide in from the right edge of the screen.
    case right
    /// Appear centered on the screen.
    case center

    // MARK: - Size

    /// Default size as a fraction of the screen's visible area.
    func defaultSize(on screen: NSScreen) -> NSSize {
        let visible = screen.visibleFrame.size
        switch self {
        case .top, .bottom:
            return NSSize(width: visible.width, height: round(visible.height * 0.4))
        case .left, .right:
            return NSSize(width: round(visible.width * 0.4), height: visible.height)
        case .center:
            return NSSize(width: round(visible.width * 0.6), height: round(visible.height * 0.6))
        }
    }

    // MARK: - Origins

    /// Origin that places the window off-screen (hidden).
    func initialOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let size = window.frame.size
        switch self {
        case .top:
            return CGPoint(
                x: round(visible.origin.x + (visible.width - size.width) / 2),
                y: visible.maxY
            )
        case .bottom:
            return CGPoint(
                x: round(visible.origin.x + (visible.width - size.width) / 2),
                y: visible.minY - size.height
            )
        case .left:
            return CGPoint(
                x: visible.minX - size.width,
                y: round(visible.origin.y + (visible.height - size.height) / 2)
            )
        case .right:
            return CGPoint(
                x: visible.maxX,
                y: round(visible.origin.y + (visible.height - size.height) / 2)
            )
        case .center:
            return CGPoint(
                x: round(visible.origin.x + (visible.width - size.width) / 2),
                y: round(visible.origin.y + (visible.height - size.height) / 2)
            )
        }
    }

    /// Origin that places the window in its final visible position.
    func finalOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let size = window.frame.size
        switch self {
        case .top:
            return CGPoint(
                x: round(visible.origin.x + (visible.width - size.width) / 2),
                y: visible.maxY - size.height
            )
        case .bottom:
            return CGPoint(
                x: round(visible.origin.x + (visible.width - size.width) / 2),
                y: visible.minY
            )
        case .left:
            return CGPoint(
                x: visible.minX,
                y: round(visible.origin.y + (visible.height - size.height) / 2)
            )
        case .right:
            return CGPoint(
                x: visible.maxX - size.width,
                y: round(visible.origin.y + (visible.height - size.height) / 2)
            )
        case .center:
            return CGPoint(
                x: round(visible.origin.x + (visible.width - size.width) / 2),
                y: round(visible.origin.y + (visible.height - size.height) / 2)
            )
        }
    }

    // MARK: - Window manipulation

    /// Move the window to its off-screen (hidden) position.
    func setInitial(in window: NSWindow, on screen: NSScreen) {
        window.alphaValue = 0
        window.setFrame(
            NSRect(origin: initialOrigin(for: window, on: screen), size: window.frame.size),
            display: false
        )
    }

    /// Move the window to its final on-screen position.
    func setFinal(in window: NSWindow, on screen: NSScreen) {
        window.alphaValue = 1
        window.setFrame(
            NSRect(origin: finalOrigin(for: window, on: screen), size: window.frame.size),
            display: true
        )
    }
}
