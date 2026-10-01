public import AppKit

/// Paints the last snapshot of a discarded page over its replacement web view
/// until the restored document paints, with a small "Restoring" badge so the
/// user can tell the page is not live yet.
///
/// The overlay never takes mouse events: clicks, scrolls and drags reach the
/// web view underneath, which is already loading the restored page.
@MainActor
public final class BrowserPageSnapshotOverlayView: NSView {
    private let imageView = NSImageView()
    private let badge = NSView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    /// - Parameters:
    ///   - snapshot: The page as it looked before the discard, or nil to show
    ///     only the badge.
    ///   - restoringLabel: Localized badge text supplied by the app.
    public init(snapshot: BrowserPageSnapshotImage?, restoringLabel: String) {
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(restoringLabel)

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

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 11
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = restoringLabel
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(spinner)
        badge.addSubview(label)
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            badge.heightAnchor.constraint(equalToConstant: 22),
            spinner.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        spinner.startAnimation(nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    /// Whether the overlay carries a page snapshot, not just the badge.
    public var showsSnapshot: Bool { imageView.image != nil }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Covers `webView`'s bounds and follows its size.
    public func install(over webView: NSView) {
        frame = webView.bounds
        webView.addSubview(self, positioned: .above, relativeTo: nil)
    }

    public func dismiss() {
        spinner.stopAnimation(nil)
        removeFromSuperview()
    }
}
