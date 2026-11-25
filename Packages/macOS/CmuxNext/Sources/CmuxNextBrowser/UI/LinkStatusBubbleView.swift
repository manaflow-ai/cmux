import AppKit
import CmuxNextDesign

/// The hovered link's address at the bottom left of the page, as Chrome's
/// status bubble shows it (``BrowserTab/linkStatus``).
///
/// Chrome's own bubble is off in cmux: it was a child window of the page
/// window, outside cmux's page clip, and drew over other panes (user,
/// 2026-11-03: a link in a pane right of the Home dock showed its address
/// over the Home chat). This one floats on the window's overlay host
/// (`PageFloatingOverlays`), clipped to its own page area, and never takes a
/// click. A long address is cut in the middle, at most half the page wide.
final class LinkStatusBubbleView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var maxWidth: NSLayoutConstraint?
    private let density = DensityBinding()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Glass over the live page with the neutral veil, as the notice pill (overlays are never solid).
        let content = OverlayBackingView()
        content.addSubview(label)
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: BrowserMetrics.overlayCornerRadius, interactive: false)
        addSubview(glass)
        let maxWidth = widthAnchor.constraint(lessThanOrEqualToConstant: 480)
        self.maxWidth = maxWidth
        let leading = label.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        let trailing = content.trailingAnchor.constraint(equalTo: label.trailingAnchor)
        NSLayoutConstraint.activate([
            leading, trailing,
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalTo: label.heightAnchor, constant: 6),
            maxWidth,
        ])
        density.update { [label] in
            label.font = BrowserMetrics.captionFont
            leading.constant = BrowserMetrics.overlayPadding
            trailing.constant = BrowserMetrics.overlayPadding
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
        }
        // Without this the values above never apply: the address ran edge to edge in the label font.
        density.start()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The address shown.
    var text: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
        }
    }

    /// Caps the bubble at half of a page `width` points wide (Chrome: a third, widening on a pause).
    func fit(pageWidth: CGFloat) {
        let cap = max(120, (pageWidth / 2).rounded(.down))
        if maxWidth?.constant != cap { maxWidth?.constant = cap }
    }

    /// A bubble never takes the mouse: the page under it keeps its hover and clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { label.textColor = Palette.textSecondary }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        performWithTheme { label.textColor = Palette.textSecondary }
    }
}
