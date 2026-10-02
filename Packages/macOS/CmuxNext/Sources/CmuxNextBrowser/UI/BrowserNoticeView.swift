import AppKit
import CmuxNextDesign

/// A small glass pill at the bottom of the page with one line of text and a
/// close button: a subtle, dismissible notice (the WebKit fallback when
/// Chromium cannot start). It never takes focus.
final class BrowserNoticeView: NSView {
    var onClose: (() -> Void)?
    /// Set while the close animation runs; a new notice then gets a new view.
    var isDismissing = false
    private let label = NSTextField(labelWithString: "")
    private let density = DensityBinding()
    /// The card's material: glass, or opaque under Reduce Transparency.
    private(set) var glass: OverlaySurfaceView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = ChromeIconButton(symbol: "xmark", label: Strings.dismissNotice, action: #selector(close), target: self)

        let stack = NSStackView(views: [label, close])
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = OverlayBackingView()
        content.addSubview(stack)
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: BrowserMetrics.overlayCornerRadius)
        addSubview(glass)
        self.glass = glass
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            density.bind(heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.findBarHeight },
            density.bind(widthAnchor.constraint(lessThanOrEqualToConstant: 0)) { BrowserMetrics.promptMaxWidth },
        ])
        density.update { [label] in
            label.font = BrowserMetrics.bodyFont
            stack.spacing = BrowserMetrics.itemSpacing
            stack.edgeInsets = NSEdgeInsets(top: 0, left: BrowserMetrics.overlayPadding, bottom: 0, right: BrowserMetrics.buttonSpacing)
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            label.textColor = Palette.textSecondary
            glass?.applyTheme()
        }
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    @objc private func close() { onClose?() }
}
