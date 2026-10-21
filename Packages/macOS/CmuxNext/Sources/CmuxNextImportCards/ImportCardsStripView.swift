public import AppKit
import CmuxNextDesign
import CmuxNextImportSuggestions
import Observation

/// Home's import cards: at most ``shown`` of the Home list, floating under the
/// transcript's header, with Show All for Settings › Import. Each card is the
/// source app's icon, what was found, what the import gives and its buttons;
/// a running import shows its progress. Gone when there is nothing to show.
@MainActor
public final class ImportCardsStripView: NSView {
    /// The most cards Home draws at once.
    static let shown = 2
    /// The column's header the strip sits under (`HomeNativeTranscriptView.headerHeight`).
    static let headerHeight: CGFloat = 80
    /// The widest the strip gets, centered in the column.
    static let maximumWidth: CGFloat = 520

    private let center: ImportSuggestionsCenter
    private let stack = NSStackView()
    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let showAll = NSButton(title: "", target: nil, action: nil)
    private var drawn: ImportCardList?

    /// Adds the strip to `host` over `column` (Home's transcript column), so the conversation
    /// views the column adds later stay under it.
    @discardableResult
    public static func mount(over column: NSView, in host: NSView, center: ImportSuggestionsCenter = .shared) -> ImportCardsStripView {
        let strip = ImportCardsStripView(center: center)
        strip.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(strip, positioned: .above, relativeTo: nil)
        let width = strip.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * Metrics.space5)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: column.topAnchor, constant: headerHeight + Metrics.space2),
            strip.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            strip.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth),
            width,
        ])
        return strip
    }

    init(center: ImportSuggestionsCenter) {
        self.center = center
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.home.importCards")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        titleLabel.font = Typography.header
        showAll.isBordered = false
        showAll.font = Typography.caption
        showAll.target = self
        showAll.action = #selector(openSettings)
        header.orientation = .horizontal
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(showAll)
        ColumnTopOverlays.shared.register(self)
        follow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawn.map(draw)
    }

    /// The column's first-run panel starts below the strip, so a new height moves it.
    public override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize.height != frame.height
        super.setFrameSize(newSize)
        if resized { ColumnTopOverlays.shared.changed() }
    }

    private func follow() {
        let list = withObservationTracking {
            center.list(for: .home)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        guard list != drawn else { return }
        draw(list)
    }

    private func draw(_ list: ImportCardList) {
        drawn = list
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = list.cards.isEmpty
        defer { ColumnTopOverlays.shared.changed() }
        guard !list.cards.isEmpty else { return }
        performWithTheme {
            titleLabel.textColor = Palette.textSecondary
            showAll.contentTintColor = Palette.accent
        }
        titleLabel.stringValue = list.title
        showAll.title = ImportSuggestionStrings.showAll
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for card in list.cards.prefix(Self.shown) {
            let view = ImportCardView(card: card) { [weak self] action in
                try? self?.center.perform(card.id, action)
            }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func openSettings() { center.openSettings() }
}

/// One card: icon, title and facts on a row, the benefit under them, then
/// the progress or status and the buttons.
@MainActor
final class ImportCardView: NSView {
    private let card: ImportCard
    private let press: (ImportCardAction) -> Void

    init(card: ImportCard, press: @escaping (ImportCardAction) -> Void) {
        self.card = card
        self.press = press
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.importCard.\(card.id)")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(card.title)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func label(_ text: String, font: NSFont, color: NSColor, wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func build() {
        // Opaque: the strip floats over the conversation, which must not show through the card.
        let surface = CardSurfaceView(cornerRadius: Metrics.space3, reduceTransparency: .alwaysOpaque)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        let (primaryText, secondaryText, tertiaryText) = performWithTheme { (Palette.textPrimary, Palette.textSecondary, Palette.textTertiary) }
        let icon = NSImageView()
        icon.image = card.app.flatMap(ImportAppIcons.image) ?? NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: ImportAppIcons.side), icon.heightAnchor.constraint(equalToConstant: ImportAppIcons.side),
        ])
        let title = label(card.title, font: Typography.bodyEmphasized, color: primaryText)
        let facts = label(card.facts, font: Typography.caption, color: tertiaryText)
        let names = NSStackView(views: [title, facts])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        let top = NSStackView(views: [icon, names])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = Metrics.space2
        var rows: [NSView] = [top]
        if let reason = card.reason { rows.append(label("“\(reason)”", font: Typography.caption, color: secondaryText, wraps: true)) }
        rows.append(label(card.benefit, font: Typography.body, color: secondaryText, wraps: true))
        if let progress = card.progress, card.state == .running || card.state == .paused {
            rows.append(ImportProgressBar(progress: progress))
        }
        if let status = card.status { rows.append(label(status, font: Typography.caption, color: secondaryText, wraps: true)) }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space2
        if let primary = card.primary {
            let button = ThemedBezelButton(title: primary.title, target: self, action: #selector(pressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(primary.action.rawValue)
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = Typography.caption
            buttons.addArrangedSubview(button)
        }
        for secondary in card.secondary {
            let button = NSButton(title: secondary.title, target: self, action: #selector(pressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(secondary.action.rawValue)
            button.isBordered = false
            button.font = Typography.caption
            button.contentTintColor = secondaryText
            buttons.addArrangedSubview(button)
        }
        if !buttons.arrangedSubviews.isEmpty { rows.append(buttons) }
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.space2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let inset = Metrics.space3
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            column.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        for row in rows where row !== top && row !== buttons {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = ImportCardAction(rawValue: raw) else { return }
        press(action)
    }
}

/// A running or paused import's share done: a 4 pt track with the accent fill, drawn in one
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
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        layer?.addSublayer(fill)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityValue(NSNumber(value: self.progress))
        heightAnchor.constraint(equalToConstant: 4).isActive = true
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
