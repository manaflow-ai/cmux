public import AppKit
public import CmuxNextActions
public import CmuxNextDesign

/// The Customize Inspector's outline around the element under the pointer: an accent ring with
/// a light wash, which never takes the mouse (the overlay is a `.dragGhost`).
public final class CustomizeInspectorOutlineView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.space1 * 1.5
        layer?.borderWidth = 2
        setAccessibilityElement(false)
        updateColors()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateColors() {
        layer?.borderColor = Palette.accent.cgColor
        layer?.backgroundColor = Palette.accent.withAlphaComponent(0.08).cgColor
    }
}

/// The Customize Inspector's card beside the outlined element (variant A of
/// `design/customize-inspector-gallery.html`): the element's name, the settings that change it and
/// the theme colors it paints with, then Change This… and Reset.
public final class CustomizeInspectorCardView: NSView {
    /// The card role's floating glass, as the shortcut hints' which-key overlay uses.
    private let surface = Glass.makeSurface(.card)
    private let titleLabel = NSTextField(labelWithString: "")
    private let settingsLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "")
    private let changeButton = ThemedBezelButton(title: CustomizeInspectorCardView.changeTitle, target: nil, action: nil)
    private let resetButton = ThemedBezelButton(title: CustomizeInspectorCardView.resetTitle, target: nil, action: nil)
    private var change: () -> Void = {}
    private var reset: () -> Void = {}
    /// The most settings and colors the card lists; the chat Change This… opens knows them all.
    static let shownSettings = 4, shownTokens = 5

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = Typography.bodyEmphasized
        for label in [settingsLabel, tokensLabel] {
            label.font = Typography.caption
            label.textColor = Palette.textSecondary
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = Self.shownSettings
        }
        titleLabel.textColor = Palette.textPrimary
        changeButton.target = self
        changeButton.action = #selector(changeClicked)
        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        let buttons = NSStackView(views: [resetButton, changeButton])
        buttons.spacing = Metrics.space2
        let stack = NSStackView(views: [titleLabel, settingsLabel, tokensLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space3, left: Metrics.space3, bottom: Metrics.space3, right: Metrics.space3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        addSubview(stack)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 260),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Fills the card for `element`.
    public func show(_ element: CustomizeElement, change: @escaping () -> Void, reset: @escaping () -> Void) {
        (self.change, self.reset) = (change, reset)
        titleLabel.stringValue = element.title
        setAccessibilityLabel(element.title)
        settingsLabel.stringValue = Self.lines(element.settings, max: Self.shownSettings)
        tokensLabel.stringValue = Self.lines(element.tokens, max: Self.shownTokens, separator: " · ")
        resetButton.isEnabled = !element.settings.isEmpty
        setFrameSize(fittingSize)
    }

    /// `items` as the card lists them: the first `max`, then "+N" for the rest.
    nonisolated static func lines(_ items: [String], max: Int, separator: String = "\n") -> String {
        let shown = items.prefix(max).joined(separator: separator)
        return items.count > max ? shown + separator + "+\(items.count - max)" : shown
    }

    /// The Change This… button, for tests.
    public var changeControl: NSButton { changeButton }
    /// The Reset button, for tests.
    public var resetControl: NSButton { resetButton }
    /// The card's text as shown, for tests: the title, the settings and the colors.
    public var shownText: [String] { [titleLabel.stringValue, settingsLabel.stringValue, tokensLabel.stringValue] }

    @objc private func changeClicked() { change() }
    @objc private func resetClicked() { reset() }

    static var changeTitle: String {
        String(localized: "customizeInspector.change", defaultValue: "Change This…", table: "CustomizeInspector", bundle: .module)
    }

    static var resetTitle: String {
        String(localized: "customizeInspector.reset", defaultValue: "Reset", table: "CustomizeInspector", bundle: .module)
    }
}
