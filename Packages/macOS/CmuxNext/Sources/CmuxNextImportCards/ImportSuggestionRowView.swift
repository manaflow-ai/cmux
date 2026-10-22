public import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextImportSuggestions
import Observation

/// Home's import suggestion: one compact row on the Chief's front page (the empty Chief
/// conversation's first-run panel), never over a conversation. It shows the first card of the
/// Home list: the source app's icon, its name over what was found ("Claude Code", "1,002
/// sessions"), its button and Not Now; Show All opens Settings › Import when there are more. A
/// running import shows its status and a thin progress line. Hidden when there is nothing to
/// suggest. (Leo 2026-10-21 on nightly 331e2e9: the floating strip of cards it replaces sat over
/// the chat, which showed through and around it.)
///
/// It fits any width the front page gives it (the narrowest Home pane included): the name and
/// what was found keep their whole width first, then Show All goes, then Not Now becomes an ✕,
/// then the app icon goes; past that the name and then the button truncate. Nothing ever lays
/// out past the glass. It follows the front page's interface scale (``applyScale(_:)``).
@MainActor
public final class ImportSuggestionRowView: NSView {
    /// The row's height at scale 1: the name over what was found, with the buttons beside them.
    static let height: CGFloat = 40
    /// The source app's icon side at scale 1.
    static let iconSide: CGFloat = 20
    /// The corner radius at scale 1, the front page's rows' (`HomeFirstRunRow.cornerRadius`).
    static let cornerRadius: CGFloat = 8
    /// The least room the name keeps before the buttons give way, at scale 1.
    static let namesFloor: CGFloat = 64

    /// What the row drops to fit, in order.
    nonisolated enum Fit: Int, CaseIterable, Comparable {
        case full, noShowAll, compactDismiss, noIcon

        static func < (lhs: Fit, rhs: Fit) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The sidebar cards' glass veil, never an opaque card.
    let surface: CardSurfaceView
    let icon = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let factsLabel = NSTextField(labelWithString: "")
    /// The shown card's buttons: its primary, then Not Now (or Done). More Options… stays in
    /// Settings › Import, behind Show All.
    private(set) var actions: [NSButton] = []
    let showAll = NSButton(title: "", target: nil, action: nil)
    /// The interface scale (``applyScale(_:)``).
    private(set) var scale: CGFloat = 1
    /// What the row dropped to fit its width.
    private(set) var fit = Fit.full
    private let buttons = NSStackView()
    private let line = NSStackView()
    private var progress: ImportProgressBar?
    private var drawn: ImportCardList?
    private var card: ImportCard?
    private let press: (String, ImportCardAction) -> Void
    private let openAll: () -> Void
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
    private lazy var iconWidth = icon.widthAnchor.constraint(equalToConstant: Self.iconSide)
    private lazy var iconHeight = icon.heightAnchor.constraint(equalToConstant: Self.iconSide)
    private lazy var leading = line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3)
    private lazy var trailing = line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space3)
    /// Not Now's width as words, measured while it shows them.
    private var dismissTextWidth: CGFloat = 0
    /// Called after the row shows, hides or changes: the panel holding it lays out again.
    public var onChange: () -> Void = {}

    /// A row that follows `center`'s Home list and runs its buttons there.
    public convenience init(center: ImportSuggestionsCenter = .shared) {
        self.init(press: { [weak center] id, action in try? center?.perform(id, action) },
                  showAll: { [weak center] in center?.openSettings() })
        follow(center)
    }

    init(press: @escaping (String, ImportCardAction) -> Void, showAll: @escaping () -> Void,
         reduceTransparency: ReduceTransparency = .shared) {
        self.press = press
        openAll = showAll
        surface = CardSurfaceView(cornerRadius: Self.cornerRadius, reduceTransparency: reduceTransparency)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.home.importSuggestion")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        build()
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: (Self.height * scale).rounded())
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// A new width picks what the row drops to fit it.
    public override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize.width != frame.width
        super.setFrameSize(newSize)
        if resized { applyFit() }
    }

    /// The front page's interface scale: the row's height, type, icon, insets and corners.
    public func applyScale(_ scale: CGFloat) {
        guard scale > 0, scale != self.scale else { return }
        self.scale = scale
        applyMetrics()
        invalidateIntrinsicContentSize()
        applyFit()
        onChange()
    }

    private func build() {
        // Overflow past the glass is clipped; the fit below keeps every control inside it.
        clipsToBounds = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        for label in [titleLabel, factsLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        showAll.isBordered = false
        showAll.target = self
        showAll.action = #selector(openSettings)
        showAll.title = ImportSuggestionStrings.showAll
        showAll.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        buttons.setHuggingPriority(.required, for: .horizontal)
        // The name over what was found, so the buttons keep their room in the front page's column.
        let names = NSStackView(views: [titleLabel, factsLabel])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 0
        names.setHuggingPriority(.defaultLow, for: .horizontal)
        for view in [icon, names, buttons] { line.addArrangedSubview(view) }
        line.orientation = .horizontal
        line.distribution = .fill
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        // Never a conflict: the trailing edge yields (clipped) only past the fit's last step.
        trailing.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            heightConstraint, iconWidth, iconHeight, leading, trailing,
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyMetrics()
    }

    /// Sizes, insets and type at the current scale (from `Typography`, scaled).
    private func applyMetrics() {
        heightConstraint.constant = (Self.height * scale).rounded()
        iconWidth.constant = Self.iconSide * scale
        iconHeight.constant = Self.iconSide * scale
        leading.constant = Metrics.space3 * scale
        trailing.constant = -Metrics.space3 * scale
        line.spacing = Metrics.space2 * scale
        buttons.spacing = Metrics.space3 * scale
        surface.cornerRadius = Self.cornerRadius * scale
        titleLabel.font = scaled(Typography.bodyEmphasized)
        factsLabel.font = scaled(Typography.caption)
        showAll.font = scaled(Typography.caption)
        for (index, button) in actions.enumerated() {
            button.font = scaled(index == 0 && card?.primary != nil ? Typography.bodyEmphasized : Typography.caption)
        }
        if let dismiss {
            dismiss.image = NSImage.icon(.actionClose, size: (Self.iconSide * 0.6 * scale).rounded())
            setDismiss(compact: false)
            dismissTextWidth = ceil(dismiss.intrinsicContentSize.width)
        }
    }

    private func scaled(_ font: NSFont) -> NSFont {
        scale == 1 ? font : NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
    }

    /// The card's Not Now (or Done), the button that turns into an ✕ in a narrow row.
    private var dismiss: NSButton? {
        actions.first { button in
            button.identifier.map { [ImportCardAction.dismiss.rawValue, ImportCardAction.hide.rawValue].contains($0.rawValue) } ?? false
        }
    }

    private func setDismiss(compact: Bool) {
        guard let dismiss else { return }
        dismiss.imagePosition = compact ? .imageOnly : .noImage
        dismiss.toolTip = compact ? dismiss.title : nil
    }

    /// Picks the first step at which the buttons fit beside the whole name; else the first at
    /// which they fit beside ``namesFloor``; else the last.
    private func applyFit() {
        guard card != nil, bounds.width > 0 else { return }
        let names = ceil(max(titleLabel.intrinsicContentSize.width, factsLabel.intrinsicContentSize.width))
        let floor = min(names, Self.namesFloor * scale)
        let chosen = Fit.allCases.first { room(at: $0) >= names } ?? Fit.allCases.first { room(at: $0) >= floor } ?? .noIcon
        fit = chosen
        showAll.isHidden = chosen >= .noShowAll || (drawn?.cards.count ?? 0) < 2
        setDismiss(compact: chosen >= .compactDismiss)
        icon.isHidden = chosen >= .noIcon
        needsLayout = true
    }

    /// The width left for the name at `fit`, after the insets, the icon and the buttons.
    private func room(at fit: Fit) -> CGFloat {
        let gap = Metrics.space2 * scale, buttonGap = Metrics.space3 * scale
        var widths: [CGFloat] = actions.map { button in
            if button === dismiss { return fit >= .compactDismiss ? (Self.iconSide * scale).rounded() : dismissTextWidth }
            return ceil(button.intrinsicContentSize.width)
        }
        if fit < .noShowAll, (drawn?.cards.count ?? 0) >= 2 { widths.append(ceil(showAll.intrinsicContentSize.width)) }
        let buttonsWidth = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * buttonGap
        let iconWidth = fit >= .noIcon ? 0 : Self.iconSide * scale + gap
        return bounds.width - 2 * Metrics.space3 * scale - iconWidth - (widths.isEmpty ? 0 : gap + buttonsWidth)
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
        actions = shown.map { item in
            let button = NSButton(title: item.title, target: self, action: #selector(pressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(item.action.rawValue)
            button.isBordered = false
            button.setAccessibilityLabel(item.title)
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
            buttons.addArrangedSubview(button)
            return button
        }
        buttons.addArrangedSubview(showAll)
        applyMetrics()
        showProgress(first)
        applyColors()
        applyFit()
    }

    private func showProgress(_ card: ImportCard) {
        progress?.removeFromSuperview()
        progress = nil
        guard let value = card.progress, card.state == .running || card.state == .paused else { return }
        let bar = ImportProgressBar(progress: value)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: line.trailingAnchor),
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
