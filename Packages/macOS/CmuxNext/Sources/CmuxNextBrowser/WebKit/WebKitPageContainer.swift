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
/// container never sets the web view's frame after adding it; a container
/// resize reaches it once through autoresizing, and WebKit re-places both.
final class WebKitPageContainer: NSView {
    init(page: NSView) {
        super.init(frame: .zero)
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        page.translatesAutoresizingMaskIntoConstraints = true
        addSubview(page)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
}
