public import AppKit

/// What changed in a ``ScrollGeometryClipView``.
public nonisolated struct ScrollGeometryChange: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The visible origin moved (a scroll).
    public static let scrolled = ScrollGeometryChange(rawValue: 1 << 0)
    /// The clip's size, the document's frame or the document itself changed.
    public static let resized = ScrollGeometryChange(rawValue: 1 << 1)
}

/// Told by a ``ScrollGeometryClipView`` each time its list scrolls or its geometry changes.
@MainActor
public protocol ScrollGeometryClient: AnyObject {
    func scrollGeometryDidChange(_ change: ScrollGeometryChange)
}

/// A clip view that tells its clients from its own geometry hooks when the list scrolls, resizes or
/// its document changes size: no frame or bounds notifications. Chromium's `views::ScrollView` does
/// the same: `ScrollToOffset` and `Layout` update its overflow indicators directly
/// (ui/views/controls/scroll_view.cc, `UpdateOverflowIndicatorVisibility`).
///
/// ``install(in:)`` puts one in a scroll view once; every client of that scroll view shares it.
public final class ScrollGeometryClipView: NSClipView {
    private struct WeakClient {
        weak var client: (any ScrollGeometryClient)?
    }

    private var clients: [WeakClient] = []
    /// The bounds the clients were last told of: each AppKit path that moves or resizes the clip
    /// tells them once, whichever of these hooks it goes through.
    private var toldBounds: NSRect = .zero

    /// The scroll view's clip, made a ``ScrollGeometryClipView`` first if it is not one: the document,
    /// background, insets and scroll position move to the new clip. Install it before anything keeps
    /// a reference to the scroll view's `contentView`.
    @discardableResult
    public static func install(in scrollView: NSScrollView) -> ScrollGeometryClipView {
        if let clip = scrollView.contentView as? ScrollGeometryClipView { return clip }
        let old = scrollView.contentView
        let document = scrollView.documentView
        let origin = old.bounds.origin
        let clip = ScrollGeometryClipView(frame: old.frame)
        clip.wantsLayer = old.wantsLayer
        clip.drawsBackground = old.drawsBackground
        clip.backgroundColor = old.backgroundColor
        clip.automaticallyAdjustsContentInsets = old.automaticallyAdjustsContentInsets
        clip.contentInsets = old.contentInsets
        clip.postsBoundsChangedNotifications = old.postsBoundsChangedNotifications
        clip.postsFrameChangedNotifications = old.postsFrameChangedNotifications
        scrollView.contentView = clip
        scrollView.documentView = document
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        return clip
    }

    /// Tells `client` of every later change until it goes away (held weakly).
    public func addClient(_ client: any ScrollGeometryClient) {
        clients.removeAll { $0.client == nil || $0.client === client }
        clients.append(WeakClient(client: client))
    }

    public override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        boundsMayHaveChanged()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        boundsMayHaveChanged()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        boundsMayHaveChanged()
    }

    public override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: newOrigin)
        boundsMayHaveChanged()
    }

    public override var bounds: NSRect {
        didSet { boundsMayHaveChanged() }
    }

    /// The document's frame changed (NSClipView's own handler for its document).
    public override func viewFrameChanged(_ notification: Notification) {
        super.viewFrameChanged(notification)
        tell(.resized)
    }

    public override var documentView: NSView? {
        didSet { if documentView !== oldValue { tell(.resized) } }
    }

    private func boundsMayHaveChanged() {
        let now = bounds
        guard now != toldBounds else { return }
        var change: ScrollGeometryChange = []
        if now.origin != toldBounds.origin { change.insert(.scrolled) }
        if now.size != toldBounds.size { change.insert(.resized) }
        toldBounds = now
        tell(change)
    }

    private func tell(_ change: ScrollGeometryChange) {
        for entry in clients { entry.client?.scrollGeometryDidChange(change) }
    }
}
