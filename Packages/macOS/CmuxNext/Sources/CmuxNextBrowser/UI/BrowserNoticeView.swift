import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A small glass pill at the bottom of the page with one line of text and a
/// close button: a subtle, dismissible notice (the WebKit fallback when
/// Chromium cannot start). It never takes focus. Its row lays out by frame
/// (`ChromeRowLayout`); `PageFloatingOverlays` sizes it with `cardSize`.
final class BrowserNoticeView: ChromeFrameView, PageFloatingCard {
    var onClose: (() -> Void)?
    /// The notice's one action (a button before the close button), if any.
    var action: (title: String, run: () -> Void)? {
        didSet {
            actionButton.title = action?.title ?? ""
            actionButton.isHidden = action == nil
            needsLayout = true // invalidate: the action button's title or presence changed the row
        }
    }
    private lazy var actionButton: ChromeTextButton = {
        let button = ChromeTextButton(title: "", prominent: false, action: #selector(runAction), target: self)
        button.isHidden = true
        return button
    }()
    /// Set while the close animation runs; a new notice then gets a new view.
    var isDismissing = false
    private let label = ChromeLabel(labelWithString: "")
    // The target is set in init (no IUOs).
    private let closeButton = ChromeIconButton(icon: .browserToolbarClose, label: Strings.dismissNotice,
                                               action: #selector(BrowserNoticeView.close), target: nil)
    /// The pill's content (the glass's), where the row lays out.
    private let content = OverlayBackingView()
    private let density = DensityBinding()
    /// The card's material: glass, or opaque under Reduce Transparency.
    private(set) var glass: OverlaySurfaceView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        closeButton.target = self
        for view in [label, actionButton, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            content.addSubview(view)
        }
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: BrowserMetrics.overlayCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        self.glass = glass
        density.update { [weak self] in
            guard let self else { return }
            label.font = BrowserMetrics.bodyFont
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
            needsLayout = true // invalidate: a design token changed the row's sizes
        }
        density.start(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The pill's row: the text, the action if any and the close button,
    /// with the overlay padding before the text.
    var rowLayout: ChromeRowLayout {
        ChromeRowLayout(spacing: BrowserMetrics.itemSpacing,
                        insets: ChromeInsets(leading: BrowserMetrics.overlayPadding, trailing: BrowserMetrics.buttonSpacing),
                        rightToLeft: laysOutRightToLeft)
    }

    private var rowViews: [NSView] {
        actionButton.isHidden ? [label, closeButton] : [label, actionButton, closeButton]
    }

    /// The pill fits its text up to the prompt width; only a narrower page
    /// truncates it (cx-whr7).
    func cardSize(maxWidth: CGFloat) -> CGSize {
        let natural = rowLayout.width(of: rowViews.map { $0.chromeLayoutSize(maxWidth: .greatestFiniteMagnitude) })
        return CGSize(width: max(min(natural, BrowserMetrics.promptMaxWidth, maxWidth), 0), height: BrowserMetrics.findBarHeight)
    }

    override func layout() {
        super.layout()
        if let glass, glass.frame != bounds { glass.frame = bounds }
        let views = rowViews
        let box = CGRect(origin: .zero, size: bounds.size)
        let rects = rowLayout.place(views.map { $0.chromeLayoutSize(maxWidth: box.width) }, in: box, flexible: 0)
        for (view, rect) in zip(views, rects) { view.setChromeLayoutRect(rect) }
    }

    // visibility-walk-allow: one text color and the glass tint in the theme scope, no layout or text measure; cheaper than a deferral
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
            needsLayout = true // invalidate: the text changed the row
        }
    }

    /// This view's tree with each frame and any label text (diagnostics:
    /// a pill drawn without its text, cx-whr7).
    var layoutReport: [String] {
        var rows: [String] = []
        func visit(_ view: NSView, _ depth: Int) {
            let text = (view as? any ShownText).map { " \"\($0.stringValue)\" intrinsic=\($0.intrinsicContentSize.width)" } ?? ""
            rows.append(String(repeating: " ", count: depth) + "\(type(of: view)) \(view.frame)\(view.isHidden ? " hidden" : "")\(text)")
            view.subviews.forEach { visit($0, depth + 1) }
        }
        visit(self, 0)
        return rows
    }

    @objc private func close() { onClose?() }

    @objc private func runAction() { action?.run() }
}
