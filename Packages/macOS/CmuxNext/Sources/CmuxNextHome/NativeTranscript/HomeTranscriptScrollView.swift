import AppKit
import CmuxHomeRender

/// The transcript's scrolling is AppKit's: an NSScrollView owns trackpad
/// phases, momentum, the mouse wheel, the scroller, keyboard and
/// accessibility scrolling, and the elastic edges. The render core keeps the
/// rows and their motion; its offset is the clip view's bounds origin.
///
/// Coordinates: the clip view is flipped and as tall as the viewport, so a
/// clip origin y is the render core's content offset. The empty document
/// view spans `minOffset ... pinnedOffset + viewport height`, so AppKit's
/// allowed range is exactly the core's. The row host is a subview of the
/// clip view (behind the document view), kept on the visible area, so the
/// window's scroll edge effect can cover it.
///
/// Two directions, never both in one pass:
/// - the clip view moved (user, momentum, rubber band) -> `hostScrolled(to:)`;
/// - the core moved its offset or range (new rows while pinned, prepend,
///   resize) -> `apply(_:)` sets the document frame and the clip origin.
final class HomeTranscriptScrollView: NSScrollView {
    let clip = FlippedClipView()
    let document = FlippedDocumentView()
    weak var controller: HomeController?
    /// The layer-hosting view of the core's root layer.
    let rowHost = NSView()
    private var applyingModel = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = true
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .allowed
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        contentView = clip
        documentView = document
        rowHost.wantsLayer = true
        clip.addSubview(rowHost, positioned: .below, relativeTo: document)
        NotificationCenter.default.addObserver(self, selector: #selector(clipMoved(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    required init?(coder: NSCoder) { nil }

    /// Rows span the full width under the scroller (a legacy scroller would
    /// narrow the clip view and cut the rows).
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    @objc private func clipMoved(_ note: Notification) {
        pinRowHost()
        guard !applyingModel, let controller else { return }
        controller.hostScrolled(to: clip.bounds.origin.y)
    }

    /// The core's range or offset changed: document frame and clip origin follow.
    func apply(_ g: HomeController.ScrollGeometry) {
        applyingModel = true
        defer { applyingModel = false }
        let height = max(clip.bounds.height, g.pinnedOffset - g.minOffset + clip.bounds.height)
        let frame = CGRect(x: 0, y: g.minOffset, width: clip.bounds.width, height: height)
        if document.frame != frame { document.frame = frame }
        if clip.bounds.origin.y != g.offset {
            clip.scroll(to: NSPoint(x: 0, y: g.offset))
            reflectScrolledClipView(clip)
        }
        pinRowHost()
    }

    /// The row host stays on the visible area whatever the clip origin.
    func pinRowHost() {
        let f = CGRect(origin: clip.bounds.origin, size: clip.bounds.size)
        guard rowHost.frame != f else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rowHost.frame = f
        CATransaction.commit()
    }
}

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
