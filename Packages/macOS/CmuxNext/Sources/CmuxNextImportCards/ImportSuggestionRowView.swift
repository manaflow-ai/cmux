public import AppKit
import CmuxNextDesign
import CmuxNextImportSuggestions
import Observation

/// Home's import suggestion: one compact row on the Chief's front page (the empty Chief
/// conversation's first-run panel), never over a conversation. It shows the first card of the
/// Home list: the source app's icon, its name and what was found ("Claude Code", "1,002
/// sessions"), its button and Not Now; Show All opens Settings › Import when there are more. A
/// running import shows its status and a thin progress line. Hidden when there is nothing to
/// suggest. (Leo 2026-10-21 on nightly 331e2e9: the floating strip of cards it replaces sat over
/// the chat, which showed through and around it.)
@MainActor
public final class ImportSuggestionRowView: NSView {
    /// The row's height: one line of controls on the front page.
    static let height: CGFloat = 40
    /// The source app's icon side.
    static let iconSide: CGFloat = 20

    /// The sidebar cards' glass veil, never an opaque card.
    let surface = CardSurfaceView(cornerRadius: 8)
    let icon = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let factsLabel = NSTextField(labelWithString: "")
    /// The shown card's buttons: its primary, then Not Now (or Done). More Options… stays in
    /// Settings › Import, behind Show All.
    private(set) var actions: [NSButton] = []
    let showAll = NSButton(title: "", target: nil, action: nil)
    private let buttons = NSStackView()
    private var progress: ImportProgressBar?
    private var drawn: ImportCardList?
    private var card: ImportCard?
    private let press: (String, ImportCardAction) -> Void
    private let openAll: () -> Void
    /// Called after the row shows, hides or changes: the panel holding it lays out again.
    public var onChange: () -> Void = {}

    /// A row that follows `center`'s Home list and runs its buttons there.
    public convenience init(center: ImportSuggestionsCenter = .shared) {
        self.init(press: { [weak center] id, action in try? center?.perform(id, action) },
                  showAll: { [weak center] in center?.openSettings() })
        follow(center)
    }

    init(press: @escaping (String, ImportCardAction) -> Void, showAll: @escaping () -> Void) {
        self.press = press
        openAll = showAll
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.home.importSuggestion")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        build()
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func build() {
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        for (label, font) in [(titleLabel, Typography.bodyEmphasized), (factsLabel, Typography.caption)] {
            label.font = font
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        // The name keeps its room before what was found does.
        titleLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(300), for: .horizontal)
        showAll.isBordered = false
        showAll.font = Typography.body
        showAll.target = self
        showAll.action = #selector(openSettings)
        showAll.title = ImportSuggestionStrings.showAll
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space3
        buttons.setHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let line = NSStackView(views: [icon, titleLabel, factsLabel, spacer, buttons])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = Metrics.space2
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        let inset = Metrics.space3
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide), icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func follow(_ center: ImportSuggestionsCenter) {
        let list = withObservationTracking {
            center.list(for: .home)
        } onChange: { [weak self, weak center] in
            Task { @MainActor in
                guard let center else { return }
                self?.follow(center)
            }
        }
        show(list)
    }

    /// Shows the first card of `list`, or hides the row when it has none.
    func show(_ list: ImportCardList) {
        guard list != drawn else { return }
        drawn = list
        defer { onChange() }
        guard let first = list.cards.first else {
            card = nil
            isHidden = true
            return
        }
        card = first
        isHidden = false
        setAccessibilityLabel(first.title)
        icon.image = first.app.flatMap(ImportAppIcons.image) ?? NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        titleLabel.stringValue = first.title
        // A running, paused, finished or failed import says where it is instead of what was found.
        factsLabel.stringValue = first.status ?? first.facts
        factsLabel.toolTip = first.benefit
        for button in buttons.arrangedSubviews { buttons.removeArrangedSubview(button); button.removeFromSuperview() }
        let shown = (first.primary.map { [$0] } ?? []) + first.secondary.filter { $0.action != .more && $0.action != .restore }
        actions = shown.enumerated().map { index, item in
            let button = NSButton(title: item.title, target: self, action: #selector(pressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(item.action.rawValue)
            button.isBordered = false
            button.font = index == 0 && first.primary != nil ? Typography.bodyEmphasized : Typography.body
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            buttons.addArrangedSubview(button)
            return button
        }
        showAll.isHidden = list.cards.count < 2
        buttons.addArrangedSubview(showAll)
        showProgress(first)
        applyColors()
        needsLayout = true
    }

    private func showProgress(_ card: ImportCard) {
        progress?.removeFromSuperview()
        progress = nil
        guard let value = card.progress, card.state == .running || card.state == .paused else { return }
        let bar = ImportProgressBar(progress: value)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        let inset = Metrics.space3
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        progress = bar
    }

    /// The theme's text tiers; the card's own button in the theme's accent.
    private func applyColors() {
        let (primary, secondary, tertiary, accent) = performWithTheme {
            (Palette.textPrimary, Palette.textSecondary, Palette.textTertiary, Palette.accent)
        }
        icon.contentTintColor = secondary
        titleLabel.textColor = primary
        factsLabel.textColor = tertiary
        for (index, button) in actions.enumerated() {
            button.contentTintColor = index == 0 && card?.primary != nil ? accent : secondary
        }
        showAll.contentTintColor = secondary
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let id = card?.id, let raw = sender.identifier?.rawValue, let action = ImportCardAction(rawValue: raw) else { return }
        press(id, action)
    }

    @objc private func openSettings() { openAll() }
}

/// A running or paused import's share done: a 2 pt track with the accent fill, drawn in one
/// frame (no animation), as the web cards draw it. Not NSProgressIndicator: its bar style is
/// the system's, not the theme's, and the lint keeps it for spinners.
@MainActor
final class ImportProgressBar: NSView {
    private let progress: Double
    private let fill = CALayer()

    init(progress: Double) {
        self.progress = min(1, max(0, progress))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 1
        layer?.masksToBounds = true
        layer?.addSublayer(fill)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityValue(NSNumber(value: self.progress))
        heightAnchor.constraint(equalToConstant: 2).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let (track, accent) = performWithTheme { (Palette.separator.cgColor, Palette.accent.cgColor) }
        layer?.backgroundColor = track
        fill.backgroundColor = accent
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        CATransaction.commit()
    }
}
