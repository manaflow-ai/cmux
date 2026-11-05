public import AppKit

/// The window's content host as the curved main pane (cx-rkgu): a rounded
/// clip around the workspace content. Corners are circular (not
/// continuous) so the Chromium page mask, built from this layer's radius
/// (`CEFClipShape.clips(around:)`), matches them exactly, as for
/// `PaneClipView`. `masksToBounds` clips terminals (IOSurface and Metal
/// layers) and web views; Chromium pages are child windows and clip
/// through that mask.
public final class MainPaneCardView: NSView {
    /// Called after the frame moves or resizes (the sidebar's animation
    /// moves it every frame), so the chrome shade follows in the same pass.
    public var onFrameChange: (() -> Void)?
    /// Called when the clip comes or goes without the card moving: the window tells Chromium pages to re-read
    /// their clip shape.
    public var onClipChange: (() -> Void)?

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .circular
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        onFrameChange?()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onFrameChange?()
    }

    /// Places the workspaces a window shows side by side in these bounds (`WindowController.arrangeOnScreen`, Debug
    /// Settings `sidebar.multiView`), now and after every resize; nil while one workspace fills the host by its
    /// autoresizing mask.
    public var arrangeContent: ((CGRect) -> Void)? {
        didSet { arrangeContent?(bounds) }
    }

    override public func resizeSubviews(withOldSize oldSize: NSSize) {
        if let held = heldContentFrame { return placeContent(in: held) }
        super.resizeSubviews(withOldSize: oldSize)
        arrangeContent?(bounds)
    }

    /// One width for the content through a sidebar slide (`WindowRootView+ContentAreaMotion`):
    /// the wider of its start and its landing, so a pane, terminal or page lays out once instead
    /// of on every frame. The content rides the card's edge that moves (the sidebar's side) and the
    /// card clips it at the other; nil at rest, and clearing it fits the content to the card again.
    public struct ContentHold: Equatable {
        public var width: CGFloat
        /// The sidebar is on the right, so the card's trailing edge moves and the content rides it.
        public var ridesTrailingEdge: Bool

        public init(width: CGFloat, ridesTrailingEdge: Bool) {
            self.width = width
            self.ridesTrailingEdge = ridesTrailingEdge
        }
    }

    public var contentHold: ContentHold? {
        didSet {
            guard contentHold != oldValue else { return }
            applyClip()
            if let held = heldContentFrame {
                placeContent(in: held)
            } else if oldValue != nil {
                placeContent(in: bounds)
                arrangeContent?(bounds)
            }
        }
    }

    /// Where the held content sits in the card; nil at rest. Several workspaces side by side
    /// (`arrangeContent`) are placed by their own arrangement and never held.
    public var heldContentFrame: CGRect? {
        guard let contentHold, arrangeContent == nil else { return nil }
        let width = max(bounds.width, contentHold.width)
        return CGRect(x: contentHold.ridesTrailingEdge ? bounds.width - width : 0, y: 0, width: width, height: bounds.height)
    }

    /// Whether the card clips its content: when rounded, and while it holds content wider than
    /// itself, a square card too. That clip is what Chromium pages (`CEFClipShape.clips(around:)`) and
    /// the window overlay's rings (`OverlayPlane.roundedClip`) read for the card's edge.
    private var clips: Bool { (layer?.cornerRadius ?? 0) > 0 || contentHold != nil }

    /// Applies `clips`; returns whether it changed. A clip that comes or goes moves no page, so
    /// Chromium pages are told to re-read their clip shape.
    @discardableResult
    private func applyClip() -> Bool {
        guard let layer, layer.masksToBounds != clips else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = clips
        CATransaction.commit()
        onClipChange?()
        return true
    }

    /// The content fills `rect`: what `show` sized to the card and left to the autoresizing mask.
    /// A workspace withdrawn hidden has no mask and keeps its frame.
    private func placeContent(in rect: CGRect) {
        for view in subviews where view.autoresizingMask.contains(.width) && view.frame != rect {
            view.frame = rect
        }
    }

    /// Returns whether the radius or the clip changed. Square (0) does not clip at rest, so the
    /// flat pane behaves exactly as before the curved one existed.
    @discardableResult
    public func setCornerRadius(_ radius: CGFloat) -> Bool {
        guard let layer else { return false }
        var changed = false
        if layer.cornerRadius != radius {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.cornerRadius = radius
            CATransaction.commit()
            changed = true
        }
        return applyClip() || changed
    }
}
