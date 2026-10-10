public import AppKit
package import CmuxNextRemoteView

#if DEBUG
/// Receives the page view's keyboard and pointer events (the remote tab).
@MainActor
public protocol RemoteBrowserEventTarget: AnyObject {
    @discardableResult
    func handleKeyEquivalent(_ event: NSEvent) -> Bool
    func handleKey(_ event: NSEvent)
    func handlePointer(_ event: NSEvent)
}

/// The page area of a remote tab: decoded frames at 1:1 device pixels. The
/// browser chrome around it (tab strip, omnibar, find) is the local cmux UI
/// (RT11); only the page is remote. Its events go to `eventTarget`.
public final class RemoteBrowserContentView: NSView {
    package let video = RemoteVideoView()
    public weak var eventTarget: (any RemoteBrowserEventTarget)?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// The page's cursor (`rb.cursor`), shown over the whole page area.
    public var pageCursor: NSCursor = .arrow {
        didSet {
            guard pageCursor !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { pageCursor.set() }
        }
    }

    /// The page size in CSS pixels at the window's scale (`rb.screen`).
    public var viewport: RemoteBrowserViewport {
        RemoteBrowserViewport(bounds: bounds.size, backingScale: window?.backingScaleFactor ?? 2)
    }

    /// Called when the viewport may have changed (size or screen scale).
    public var onViewport: ((RemoteBrowserViewport) -> Void)?

    /// Called when the view may have moved on screen or been hidden or
    /// shown: a new frame, window, superview or hidden state. Popup surface
    /// panels follow the page with it.
    public var onPlacementChange: (() -> Void)?

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onViewport?(viewport)
        onPlacementChange?()
    }

    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        onPlacementChange?()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onPlacementChange?()
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onPlacementChange?()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        onPlacementChange?()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        onPlacementChange?()
    }

    /// A popup surface's view: it is in a panel that never becomes key, so
    /// the first click acts at once and hover works while the app is active
    /// (not only in the key window).
    package var isSurface = false {
        didSet {
            guard isSurface != oldValue else { return }
            if let hover { removeTrackingArea(hover) }
            hover = nil
            installHover()
        }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isSurface }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onViewport?(viewport)
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: pageCursor)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        video.autoresizingMask = [.width, .height]
        video.frame = bounds
        addSubview(video)
        installHover()
    }

    /// Why the page is not shown (a refused or lost session), drawn over
    /// the page area; nil while the page streams.
    public private(set) var failureMessage: String?
    private var failureLabel: NSTextField?

    /// Shows `message` centered in the page area (nil hides it).
    public func showFailure(_ message: String?) {
        failureMessage = message
        guard let message else {
            failureLabel?.removeFromSuperview()
            failureLabel = nil
            return
        }
        let label = failureLabel ?? NSTextField(wrappingLabelWithString: "")
        label.stringValue = message
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.isSelectable = true
        if failureLabel == nil {
            failureLabel = label
            addSubview(label)
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        guard let failureLabel else { return }
        let width = min(max(bounds.width - 48, 0), 480)
        let height = failureLabel.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        failureLabel.frame = NSRect(x: (bounds.width - width) / 2, y: max((bounds.height - height) / 2, 0), width: width, height: height)
    }

    /// Hover: mouse moves, enter and exit while the pointer is over the
    /// page (CSS `:hover`, tooltips, cursors), with no button down. Covers
    /// the visible rect, so it follows every resize by itself.
    private var hover: NSTrackingArea?

    private func installHover() {
        if let hover, trackingAreas.contains(hover) { return }
        let active: NSTrackingArea.Options = isSurface ? .activeInActiveApp : .activeInKeyWindow
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, active, .inVisibleRect], owner: self, userInfo: nil)
        hover = area
        addTrackingArea(area)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHover()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only while the page has keyboard focus: other views keep their chords.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let eventTarget else { return false }
        return eventTarget.handleKeyEquivalent(event)
    }

    public override func keyDown(with event: NSEvent) { eventTarget?.handleKey(event) }
    public override func keyUp(with event: NSEvent) { eventTarget?.handleKey(event) }
    public override func flagsChanged(with event: NSEvent) { eventTarget?.handleKey(event) }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        eventTarget?.handlePointer(event)
    }

    public override func mouseUp(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func mouseDragged(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func mouseMoved(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func mouseEntered(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func mouseExited(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func rightMouseDragged(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func otherMouseDragged(with event: NSEvent) { eventTarget?.handlePointer(event) }
    /// Wheel and trackpad scrolls go to the page (`wheel`), phases and momentum included.
    public override func scrollWheel(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func rightMouseDown(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func rightMouseUp(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func otherMouseDown(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func otherMouseUp(with event: NSEvent) { eventTarget?.handlePointer(event) }
}
#endif
