public import AppKit

/// Paints the last snapshot of a discarded page over its replacement web view
/// until the restored document paints.
///
/// The overlay never takes mouse events: clicks, scrolls and drags reach the
/// web view underneath, which is already loading the restored page. The page
/// snapshot is deliberately silent; a transient restore badge obscures the
/// content and makes a routine background memory operation feel like an alert.
public final class BrowserPageSnapshotOverlayView: NSView {
    private let imageView = NSImageView()

    public nonisolated override var isFlipped: Bool { true }
    public nonisolated override var isOpaque: Bool { false }

    /// - Parameter snapshot: The page as it looked before the discard.
    public init(snapshot: BrowserPageSnapshotImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        if let snapshot, let image = NSImage(data: snapshot.jpegData) {
            image.size = snapshot.pointSize
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.imageFrameStyle = .none
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    /// Whether the overlay carries a page snapshot, not just the badge.
    public var showsSnapshot: Bool { imageView.image != nil }

    public nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Covers `webView`'s bounds and follows its size.
    public func install(over webView: NSView) {
        frame = webView.bounds
        webView.addSubview(self, positioned: .above, relativeTo: nil)
    }

    public func dismiss() {
        removeFromSuperview()
    }
}
