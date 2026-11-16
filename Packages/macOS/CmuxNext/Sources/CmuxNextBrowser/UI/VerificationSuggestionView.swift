import AppKit
import CmuxNextDesign

/// The code suggestion under a page's code field (plans/cmux-next/email-verification-autofill/
/// DESIGN.md "Delivery"): "Fill code 482 913" over "From slack.com", like macOS's "From Messages"
/// suggestion. It is native chrome on the window's overlay host, so page script cannot read,
/// style or click it. A click on it, or Return once it is selected (Down Arrow), fills the code;
/// its close button or Escape declines. It never takes focus from the page.
final class VerificationSuggestionView: NSView {
    /// The person accepted (click, or Return while selected).
    var onAccept: (() -> Void)?
    /// The person declined (close button, Escape).
    var onDecline: (() -> Void)?
    /// Set while the close animation runs; a new offer then gets a new view.
    var isDismissing = false
    /// The prompt it shows.
    private(set) var prompt: BrowserPrompt?
    /// Where the field is (viewport fractions); the chrome places the card under it.
    var anchor: VerificationFieldAnchor?
    /// Down Arrow selected it: Return now fills.
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            hover.state.selected = isSelected
            keyHint.isHidden = !isSelected
        }
    }

    private let icon = ThemedImageView()
    private let title = ThemedLabel(labelWithString: "")
    private let detail = ThemedLabel(labelWithString: "")
    private let keyHint = ThemedLabel(labelWithString: "↩")
    private let close = ClickableButton()
    private let row = NSView()
    private lazy var hover = ChromeHover(row, cornerRadius: Metrics.buttonCornerRadius)
    private var glass: OverlaySurfaceView?
    private let density = DensityBinding()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        icon.image = NSImage.systemSymbol("envelope", accessibilityDescription: nil)
        icon.ink = .secondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.ink = .primary
        detail.ink = .secondary
        keyHint.ink = .tertiary
        keyHint.isHidden = true

        close.image = NSImage.systemSymbol("xmark", accessibilityDescription: Strings.verificationNotNow)
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.contentTintColor = nil
        close.target = self
        close.action = #selector(declineClicked)
        close.toolTip = Strings.verificationNotNow
        close.setAccessibilityLabel(Strings.verificationNotNow)
        close.translatesAutoresizingMaskIntoConstraints = false

        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, texts, keyHint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }

        let content = OverlayBackingView()
        content.addSubview(row)
        content.addSubview(close)
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: BrowserMetrics.overlayCornerRadius)
        addSubview(glass)
        self.glass = glass
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            density.bind(row.leadingAnchor.constraint(equalTo: content.leadingAnchor)) { Metrics.space2 },
            density.bind(row.topAnchor.constraint(equalTo: content.topAnchor)) { Metrics.space2 },
            density.bind(content.bottomAnchor.constraint(equalTo: row.bottomAnchor)) { Metrics.space2 },
            density.bind(close.leadingAnchor.constraint(equalTo: row.trailingAnchor)) { Metrics.space1 },
            density.bind(content.trailingAnchor.constraint(equalTo: close.trailingAnchor)) { Metrics.space2 },
            close.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            density.bind(close.widthAnchor.constraint(equalToConstant: 0)) { Metrics.controlHeight },
            close.heightAnchor.constraint(equalTo: close.widthAnchor),
            density.bind(icon.leadingAnchor.constraint(equalTo: row.leadingAnchor)) { Metrics.space2 },
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            density.bind(texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor)) { Metrics.space3 },
            density.bind(texts.topAnchor.constraint(equalTo: row.topAnchor)) { Metrics.space2 },
            density.bind(row.bottomAnchor.constraint(equalTo: texts.bottomAnchor)) { Metrics.space2 },
            density.bind(keyHint.leadingAnchor.constraint(greaterThanOrEqualTo: texts.trailingAnchor)) { Metrics.space3 },
            density.bind(row.trailingAnchor.constraint(equalTo: keyHint.trailingAnchor)) { Metrics.space2 },
            keyHint.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        density.update { [weak self] in
            guard let self else { return }
            title.font = Typography.system(.monospacedDigit, size: Typography.bodyEmphasized.pointSize, weight: .medium)
            detail.font = BrowserMetrics.captionFont
            keyHint.font = BrowserMetrics.captionFont
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: BrowserMetrics.symbolPointSize, weight: .regular)
            close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: BrowserMetrics.symbolPointSize, weight: .regular)
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
        }
        density.start()
        hover.followPointer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `prompt`'s code offer: the code grouped for reading, and the sender's site.
    func show(_ prompt: BrowserPrompt, offer: VerificationOffer) {
        self.prompt = prompt
        let code = offer.code.map(Self.grouped) ?? ""
        title.stringValue = Strings.verificationSuggestionFill(code: code)
        detail.stringValue = Strings.verificationSuggestionFrom(site: offer.senderSite)
        setAccessibilityLabel("\(title.stringValue), \(detail.stringValue)")
        isSelected = false
    }

    /// The code as it reads best: six or eight characters in two groups ("482 913").
    static func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let half = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<half])\u{2009}\(code[half...])"
    }

    // The row takes the click: a press shows only the hover fill's pressed step.
    override func mouseDown(with event: NSEvent) {
        guard row.frame.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        hover.state.pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = hover.state.pressed
        hover.state.pressed = false
        guard wasPressed, row.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onAccept?()
    }

    override func accessibilityPerformPress() -> Bool {
        onAccept?()
        return true
    }

    @objc private func declineClicked() { onDecline?() }
}
