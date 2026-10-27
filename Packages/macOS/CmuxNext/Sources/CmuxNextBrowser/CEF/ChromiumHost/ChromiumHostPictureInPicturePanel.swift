import AppKit

/// The cmux panel a picture-in-picture widget shows in (``ChromiumHostWidgetHost``, placement
/// ``ChromiumHostWidgetKind/Placement/floating(keepsAspectRatio:takesKey:)``): borderless, as Chromium
/// draws the window's controls in the widget; over every window and on every space, visible while cmux
/// is not the active app, as Chrome's VideoOverlayWindowViews and its document picture-in-picture
/// Browser window are (chrome/browser/ui/views/overlay/video_overlay_window_views.cc), and resized from
/// its edges.
final class ChromiumHostPictureInPicturePanel: NSPanel {
    /// The margin from the screen's visible edges where a new panel shows.
    static let margin: CGFloat = 16

    private let takesKey: Bool

    init(contentSize: CGSize, on screen: NSScreen?, keepsAspectRatio: Bool, takesKey: Bool) {
        self.takesKey = takesKey
        let frame = Self.initialFrame(contentSize: contentSize, visibleFrame: screen?.visibleFrame)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .black
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        if keepsAspectRatio { contentAspectRatio = contentSize }
        setAccessibilityIdentifier("browser.chromiumHost.pictureInPicture")
    }

    override var canBecomeKey: Bool { takesKey }
    override var canBecomeMain: Bool { false }

    /// The host sent a new size (the video's aspect ratio, the page's `resizeTo`): the panel takes it and
    /// keeps its top left where the person put it.
    func take(contentSize: CGSize, keepsAspectRatio: Bool) {
        if keepsAspectRatio { contentAspectRatio = contentSize }
        let content = contentRect(forFrameRect: frame)
        guard content.size != contentSize else { return }
        let top = frame.maxY
        var next = frameRect(forContentRect: CGRect(origin: content.origin, size: contentSize))
        next.origin.y = top - next.height
        setFrame(next, display: false)
    }

    /// A new panel's frame: the bottom right of the screen's visible frame, `margin` in, as Chrome first
    /// places its picture-in-picture window; the size alone without a screen.
    static func initialFrame(contentSize: CGSize, visibleFrame: CGRect?) -> CGRect {
        guard let visible = visibleFrame, contentSize.width > 0, contentSize.height > 0 else {
            return CGRect(origin: .zero, size: contentSize)
        }
        // Too large for the screen: scaled down whole, so the shape stays.
        let scale = min(1, (visible.width - 2 * margin) / contentSize.width, (visible.height - 2 * margin) / contentSize.height)
        let size = CGSize(width: (contentSize.width * scale).rounded(), height: (contentSize.height * scale).rounded())
        return CGRect(x: visible.maxX - margin - size.width, y: visible.minY + margin, width: size.width, height: size.height)
    }
}
