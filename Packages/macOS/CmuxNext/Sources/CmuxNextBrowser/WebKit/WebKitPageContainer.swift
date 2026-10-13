import AppKit

/// A WebKit tab's `contentView`: the parent of the `WKWebView`, owned by
/// the tab. The chrome pins this container with Auto Layout; the web view
/// inside uses only autoresizing.
///
/// WebKit's attached Web Inspector (WebInspectorUIProxyMac) adds its view to
/// the web view's superview and sets the web view's frame to the area left,
/// and applies that again whenever the web view's frame changes. It must be
/// the only owner of the web view's frame while attached: when the chrome
/// pinned the web view itself, every layout pass reset it to full size and
/// WebKit shrank it back, so the inspector flickered on every frame. This
/// container never sets the web view's frame after adding it while the
/// inspector is attached; a container resize reaches it once through
/// autoresizing, and WebKit re-places both. Device emulation places the web
/// view itself only while it is alone in the container.
final class WebKitPageContainer: NSView {
    /// The web view; WebKit owns its frame (an attached inspector shrinks it).
    private(set) weak var page: NSView?

    init(page: NSView) {
        self.page = page
        super.init(frame: .zero)
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        page.translatesAutoresizingMaskIntoConstraints = true
        addSubview(page)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    /// WebKit added or removed a view beside the page (the attached Web
    /// Inspector shows and hides this way).
    var onSubviewsChange: (() -> Void)?

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        onSubviewsChange?()
        if emulatedSize != nil { needsLayout = true }
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        onSubviewsChange?()
        if emulatedSize != nil { needsLayout = true }
    }

    // MARK: Device emulation (WebKitTab+DeviceEmulation)

    /// The emulated device's CSS size, nil for none. The web view gets
    /// exactly this size, centered at the top, and the container scales its
    /// bounds when the device is bigger than the pane (Chrome's fit), so the
    /// page's viewport stays the device's. While an attached Web Inspector
    /// shares the container, WebKit owns the web view's frame: the container
    /// then keeps unscaled bounds and autoresizing and leaves the frame alone
    /// (only the user agent and scale factor apply); when the inspector goes,
    /// the device size returns.
    var emulatedSize: CGSize? {
        didSet {
            guard emulatedSize != oldValue else { return }
            placeEmulatedPage()
        }
    }

    override func layout() {
        super.layout()
        placeEmulatedPage()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if emulatedSize != nil { placeEmulatedPage() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard emulatedSize != nil, subviews.count == 1 else { return super.resizeSubviews(withOldSize: oldSize) }
        placeEmulatedPage()
    }

    private var isScaledForEmulation = false

    private func placeEmulatedPage() {
        guard let page else { return }
        guard let size = emulatedSize, subviews.count == 1, frame.width > 0, frame.height > 0 else {
            // No emulation, or the inspector owns the web view's frame.
            guard isScaledForEmulation else { return }
            isScaledForEmulation = false
            setBoundsSize(frame.size)
            setBoundsOrigin(.zero)
            page.autoresizingMask = [.width, .height]
            if subviews.count == 1 { page.frame = bounds }
            return
        }
        isScaledForEmulation = true
        let scale = min(1, frame.width / size.width, frame.height / size.height)
        let scaled = CGSize(width: frame.width / scale, height: frame.height / scale)
        if bounds.size != scaled { setBoundsSize(scaled) }
        if bounds.origin != .zero { setBoundsOrigin(.zero) }
        page.autoresizingMask = []
        // Not flipped: the top edge is maxY.
        let target = CGRect(x: ((scaled.width - size.width) / 2).rounded(.down), y: scaled.height - size.height,
                            width: size.width, height: size.height)
        if page.frame != target { page.frame = target }
    }
}
