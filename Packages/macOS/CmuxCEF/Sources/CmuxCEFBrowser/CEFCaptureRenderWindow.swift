import AppKit

/// Holds a Chromium page that no window shows (its pane is in a workspace
/// that has not been on screen) in an off-screen window while a capture runs.
///
/// With no window, Chromium draws no frames and `Page.captureScreenshot`
/// waits forever. In this window the page draws, and nothing reaches a
/// display: the window lies outside every screen, is transparent, ignores
/// the mouse, sits behind every window and never becomes key or main.
/// The page's Chromium window follows its host view into it.
@MainActor
final class CEFCaptureRenderWindow {
    /// The page size when the parked view has none.
    static let defaultSize = NSSize(width: 1280, height: 800)

    private let panel: CEFCaptureRenderPanel
    private let view: NSView
    private weak var previousSuperview: NSView?
    private weak var restoreAnchor: NSView?
    private let restorePosition: NSWindow.OrderingMode
    private let previousFrame: NSRect
    private let previousAutoresizingMask: NSView.AutoresizingMask

    /// Moves `view` (the page's content view) into a new render window.
    init(parking view: NSView) {
        self.view = view
        previousSuperview = view.superview
        previousFrame = view.frame
        previousAutoresizingMask = view.autoresizingMask
        let siblings = view.superview?.subviews ?? []
        if let index = siblings.firstIndex(of: view), index > 0 {
            restoreAnchor = siblings[index - 1]
            restorePosition = .above
        } else {
            restoreAnchor = siblings.count > 1 ? siblings[1] : nil
            restorePosition = .below
        }
        let size = view.frame.width >= 1 && view.frame.height >= 1 ? view.frame.size : Self.defaultSize
        panel = CEFCaptureRenderPanel(
            contentRect: Self.frame(for: size, screens: NSScreen.screens.map(\.frame)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.chromiumCaptureRender")
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .stationary, .canJoinAllSpaces]
        panel.isExcludedFromWindowsMenu = true
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = content
        panel.orderBack(nil)
        view.removeFromSuperview()
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        content.layoutSubtreeIfNeeded()
    }

    /// Puts the view back where it was and closes the window. A pane that
    /// took the view meanwhile (its workspace came on screen) keeps it.
    func restore() {
        if view.superview === panel.contentView {
            view.removeFromSuperview()
            view.frame = previousFrame
            view.autoresizingMask = previousAutoresizingMask
            if let previousSuperview {
                if let restoreAnchor, restoreAnchor.superview === previousSuperview {
                    previousSuperview.addSubview(view, positioned: restorePosition, relativeTo: restoreAnchor)
                } else {
                    previousSuperview.addSubview(view)
                }
            }
        }
        panel.orderOut(nil)
        panel.close()
    }

    /// The frame of a render window of `size`: left of and below every
    /// screen, with a margin, so a screen added later at the old edge does
    /// not overlap it at once.
    nonisolated static func frame(for size: NSSize, screens: [NSRect]) -> NSRect {
        let union = screens.reduce(NSRect.null) { $0.union($1) }
        let bounds = union.isNull ? NSRect.zero : union
        let margin: CGFloat = 10_000
        return NSRect(x: bounds.minX - size.width - margin, y: bounds.minY - size.height - margin,
                      width: size.width, height: size.height)
    }
}

/// The render window: it never takes the keys or becomes main, so the
/// person's focus never moves to it.
private final class CEFCaptureRenderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
