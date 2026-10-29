public import AppKit
public import CmuxNextDesignTokens

/// The inks a hover card row draws in, resolved in the card's theme scope (Leo 2026-10-19: the
/// Codex sidebar card and Claude desktop's PR list: "better symbolic depictions of things, maybe
/// with different colors"). Every one is a theme token, never a fixed gray.
public enum HoverCardTone: Hashable, Sendable {
    case primary, secondary, tertiary
    /// Open, online, done: the theme's ANSI green.
    case success
    /// Waiting on you, a conflict, checks running: the theme's ANSI yellow.
    case attention
    /// Failed, offline, checks failed: the theme's ANSI red.
    case danger
    /// A merged pull request: the theme's ANSI magenta.
    case merged
    /// Running now: the theme's ANSI blue.
    case working

    /// The color, in the theme scope that is active (call it inside `performWithTheme`).
    @MainActor public var color: NSColor {
        switch self {
        case .primary: Palette.textPrimary
        case .secondary: Palette.textSecondary
        case .tertiary: Palette.textTertiary
        case .success: Palette.success
        case .attention: Palette.attention
        case .danger: Palette.danger
        case .working: Palette.highlight
        case .merged:
            (ThemeContext.active ?? ThemeScope.app.tokens).ansi.dropFirst(5).first?.nsColor ?? .systemPurple
        }
    }
}

/// A row's mark on its trailing edge: a state as a symbol and color, not words.
public enum HoverCardAccessory: Hashable, Sendable {
    /// A filled dot: online, offline, a run state.
    case dot(HoverCardTone)
    /// A ring filled to `fraction` (0...1), its percentage beside it: context-window use.
    case ring(Double, tone: HoverCardTone)
    /// Recent samples (each 0...1), newest last, as tiny bars: CPU or memory over the last
    /// seconds; `tone` warms when the newest is hot.
    case bars([Double], tone: HoverCardTone)
}

/// What one hover card row shows: a leading icon (the caller's image), an optional colored status
/// word ("Merged", "Conflict", "Checks failed"), the text, optional +added and −removed counts in
/// green and red, and an optional trailing mark. Pure.
public struct HoverCardRowContent: Hashable, Sendable {
    public var text: String
    public var ink: HoverCardTone
    /// How many lines the text may wrap to; the last one truncates.
    public var lines: Int
    public var status: String?
    public var statusTone: HoverCardTone
    public var additions: Int?
    public var deletions: Int?
    public var accessory: HoverCardAccessory?
    /// The leading icon's own ink (a pull request's state color, a wait's attention); nil draws
    /// it in the machine's color pick (`iconMachine`), else the secondary ink like every other
    /// row's icon.
    public var iconTone: HoverCardTone?
    /// The machine whose color pick (`appearance.machineColors`) the icon draws in; with no pick
    /// (or nil) the icon keeps textSecondary.
    public var iconMachine: String?

    public init(text: String, ink: HoverCardTone = .secondary, lines: Int = 1, status: String? = nil,
                statusTone: HoverCardTone = .secondary, additions: Int? = nil, deletions: Int? = nil,
                accessory: HoverCardAccessory? = nil, iconTone: HoverCardTone? = nil, iconMachine: String? = nil) {
        self.iconTone = iconTone
        self.text = text
        self.ink = ink
        self.lines = lines
        self.status = status
        self.statusTone = statusTone
        self.additions = additions
        self.deletions = deletions
        self.accessory = accessory
        self.iconMachine = iconMachine
    }

    /// "+12", "−3": the counts as they read.
    public var additionsText: String? { additions.map { "+\($0)" } }
    public var deletionsText: String? { deletions.map { "\u{2212}\($0)" } }

    /// The row as one line of text, in reading order (tests, `debug.hover_cards`, accessibility).
    public var spoken: String {
        [status, text, additionsText, deletionsText, accessory?.spoken].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension HoverCardAccessory {
    /// The ring's percentage ("62%"); nil for a mark without words.
    public var label: String? {
        guard case .ring(let fraction, _) = self else { return nil }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    var spoken: String? { label }

    var tone: HoverCardTone {
        switch self {
        case .dot(let tone), .ring(_, let tone), .bars(_, let tone): tone
        }
    }
}

/// One row of a hover card, shared by the sidebar's workspace card and the tab strip's card: the
/// icon on the card's icon column, the text beside it on one leading edge, a colored status word
/// and counts inline, and the trailing mark (a dot, a ring or bars) on the card's trailing edge.
/// The row paints no fill: the card's overlay glass is the only surface.
///
/// The parts stand on the text's first baseline; the icon and the mark center on the middle of
/// its first line's capitals (`NSFont.iconBaselineOffsetFromTop(iconHeight:)`), so a row whose
/// text wraps keeps them on its first line (Lawrence 2026-10-21).
@MainActor
public final class HoverCardRowView: NSView {
    public static var iconSize: CGFloat { 13 }

    public let icon: NSImageView
    private let iconView = HoverCardIconView()
    public let statusLabel = ChromeLabel(labelWithString: "")
    public let textLabel = ChromeLabel(labelWithString: "")
    public let additionsLabel = ChromeLabel(labelWithString: "")
    public let deletionsLabel = ChromeLabel(labelWithString: "")
    public let accessoryView = HoverCardAccessoryView()
    private let stack = NSStackView()
    public private(set) var content = HoverCardRowContent(text: "")

    public init() {
        icon = iconView
        super.init(frame: .zero)
        iconView.line = textLabel
        accessoryView.line = textLabel
        for label in [statusLabel, additionsLabel, deletionsLabel] {
            label.font = Typography.body
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        textLabel.font = Typography.body
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
        textLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        accessoryView.setContentHuggingPriority(.required, for: .horizontal)
        accessoryView.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The text and its counts read from the leading edge; the live mark sits at the trailing one.
        stack.setViews([icon, statusLabel, textLabel, additionsLabel, deletionsLabel], in: .leading)
        stack.setViews([accessoryView], in: .trailing)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = Metrics.space2
        stack.setCustomSpacing(Metrics.space1, after: additionsLabel)
        stack.setCustomSpacing(Metrics.space3, after: deletionsLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `content` beside `image`. `wrapWidth` is the text's width when it may wrap (the card
    /// sizes in one pass); `font` the text's (a running time takes digits of one width).
    public func configure(_ content: HoverCardRowContent, image: NSImage?, font: NSFont = Typography.body,
                          wrapWidth: CGFloat = 0, truncation: NSLineBreakMode = .byTruncatingTail) {
        self.content = content
        icon.image = image
        icon.isHidden = image == nil
        statusLabel.stringValue = content.status ?? ""
        statusLabel.isHidden = (content.status ?? "").isEmpty
        textLabel.stringValue = content.text
        textLabel.font = font
        textLabel.maximumNumberOfLines = content.lines
        textLabel.truncatesLastVisibleLine = true
        textLabel.lineBreakMode = content.lines > 1 ? .byWordWrapping : truncation
        textLabel.preferredMaxLayoutWidth = content.lines > 1 ? wrapWidth : 0
        additionsLabel.stringValue = content.additionsText ?? ""
        additionsLabel.isHidden = content.additions == nil
        deletionsLabel.stringValue = content.deletionsText ?? ""
        deletionsLabel.isHidden = content.deletions == nil
        accessoryView.accessory = content.accessory
        accessoryView.isHidden = content.accessory == nil
        applyColors()
    }

    /// The row's text as shown, in reading order (the status word, the text, the counts, a ring's
    /// percentage): `debug.hover_cards` and tests.
    public var shownText: String {
        [statusLabel, textLabel, additionsLabel, deletionsLabel].filter { !$0.isHidden }.map(\.stringValue)
            .appending(accessoryView.isHidden ? nil : accessoryView.accessory?.label)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Recolors the row in its theme scope; the card runs it on adopt and on every theme change.
    public func applyColors() {
        performWithTheme {
            icon.contentTintColor = content.iconTone?.color
                ?? content.iconMachine.flatMap { MachineColor(name: $0).pickedColor } ?? Palette.textSecondary
            statusLabel.textColor = content.statusTone.color
            textLabel.textColor = content.ink.color
            additionsLabel.textColor = HoverCardTone.success.color
            deletionsLabel.textColor = HoverCardTone.danger.color
        }
        accessoryView.applyColors()
    }

    /// A store repaint with no new theme (a machine color picked while the card shows) reaches
    /// the row only through this hook.
    // visibility-walk-allow: color stores only (a tint, four text colors, the accessory's layer colors), no layout or text measure; a row exists only in a shown card
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}

private extension Array where Element == String {
    func appending(_ element: String?) -> [String] { element.map { self + [$0] } ?? self }
}

/// The trailing mark of a hover card row (`HoverCardAccessory`), drawn in layers in the card's
/// theme: an 8 pt dot, a 13 pt ring with its percentage, or up to 12 bars 11 pt high.
@MainActor
public final class HoverCardAccessoryView: NSView {
    public static let maxBars = 12
    private static let dotSize: CGFloat = 8
    private static let ringSize: CGFloat = 13
    private static let ringWidth: CGFloat = 2
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 1
    private static let barsHeight: CGFloat = 11

    private let track = CAShapeLayer()
    private let mark = CAShapeLayer()
    public let percentLabel = ChromeLabel(labelWithString: "")
    /// The row's text: on a first-baseline row the mark centers on its first line's capitals.
    public weak var line: (any ShownText)?

    public var accessory: HoverCardAccessory? {
        didSet {
            guard accessory != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true // invalidate: another mark (the guard above): new paths and percentage frame.
            percentLabel.stringValue = accessory?.label ?? ""
            percentLabel.isHidden = accessory?.label == nil
            applyColors()
        }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, mark] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        percentLabel.font = Typography.system(.monospacedDigit, size: Typography.caption.pointSize, weight: .regular)
        percentLabel.isHidden = true
        addSubview(percentLabel)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The mark's own width (the ring adds its percentage).
    public override var intrinsicContentSize: NSSize {
        switch accessory {
        case .dot?: NSSize(width: Self.dotSize, height: Self.dotSize)
        case .ring?:
            NSSize(width: Self.ringSize + Metrics.space1 + percentSize.width, height: Self.ringSize)
        case .bars?: NSSize(width: CGFloat(Self.maxBars) * (Self.barWidth + Self.barGap) - Self.barGap, height: Self.barsHeight)
        case nil: NSSize(width: 0, height: 0)
        }
    }

    public override var firstBaselineOffsetFromTop: CGFloat {
        guard let font = line?.font else { return super.firstBaselineOffsetFromTop }
        return font.iconBaselineOffsetFromTop(iconHeight: intrinsicContentSize.height)
    }

    /// The percentage's natural size, rounded up so its last digit is never clipped.
    private var percentSize: NSSize {
        let size = percentLabel.attributedStringValue.size()
        return NSSize(width: ceil(size.width) + 2, height: ceil(size.height))
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        track.frame = bounds
        mark.frame = bounds
        let midY = bounds.midY
        track.path = nil
        mark.path = nil
        switch accessory {
        case .dot?:
            mark.path = CGPath.ellipse(in: CGRect(x: 0, y: midY - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize))
        case .ring(let fraction, _)?:
            let center = CGPoint(x: Self.ringSize / 2, y: midY)
            let radius = (Self.ringSize - Self.ringWidth) / 2
            track.path = CGPath.ellipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            let arc = CGMutablePath()
            // From the top, clockwise on screen (y grows up, so the angle falls).
            let start = CGFloat.pi / 2
            arc.addArc(center: center, radius: radius, startAngle: start,
                       endAngle: start - 2 * .pi * CGFloat(min(max(fraction, 0), 1)), clockwise: true)
            mark.path = arc
            let size = percentSize
            percentLabel.frame = CGRect(x: Self.ringSize + Metrics.space1, y: midY - size.height / 2, width: size.width, height: size.height)
        case .bars(let samples, _)?:
            // Bars stand on one baseline (the view is not flipped: y grows up), newest on the right.
            let path = CGMutablePath()
            let baseline = midY - Self.barsHeight / 2
            for (index, sample) in samples.suffix(Self.maxBars).enumerated() {
                let height = max(1, Self.barsHeight * CGFloat(min(max(sample, 0), 1)))
                let x = CGFloat(Self.maxBars - min(samples.count, Self.maxBars) + index) * (Self.barWidth + Self.barGap)
                path.addRect(CGRect(x: x, y: baseline, width: Self.barWidth, height: height))
            }
            mark.path = path
        case nil:
            break
        }
    }

    public func applyColors() {
        performWithTheme {
            let tone = accessory?.tone.color ?? Palette.textSecondary
            switch accessory {
            case .dot?, .bars?:
                mark.fillColor = tone.cgColor
                mark.strokeColor = nil
                track.strokeColor = nil
            case .ring?:
                mark.fillColor = nil
                mark.strokeColor = tone.cgColor
                mark.lineWidth = Self.ringWidth
                track.strokeColor = Palette.textTertiary.withAlphaComponent(0.35).cgColor
                track.lineWidth = Self.ringWidth
            case nil:
                break
            }
            percentLabel.textColor = Palette.textSecondary
        }
        // No layout: `layout()` places the paths and the percentage from the mark, never from a color.
    }
}

#if DEBUG
/// DEBUG ONLY: a gallery's hover card body on the shared overlay glass, outside the hover card
/// panel: it recolors the body when it joins a window and on every theme change, as the panel
/// does for a shown card (`debug.hover_cards {gallery}`, HoverCardGallery).
@MainActor
public final class HoverCardGalleryHost: NSView, ThemeResponsive {
    private let recolor: () -> Void
    private weak var observedScope: ThemeScope?

    public init(body: NSView, recolor: @escaping () -> Void) {
        self.recolor = recolor
        super.init(frame: .zero)
        // The real card's shape (`HoverCardPanel.cornerRadius`), so the gallery shows what a hover shows.
        let glass = Glass.makeOverlayPanel(cornerRadius: HoverCardPanel.cornerRadius, interactive: false, cardFill: false)
        body.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(body)
        addSubview(glass)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            body.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A theme switch that keeps light or dark changes no appearance: hear the nearest scope's
        // theme itself (the app's when the page has none of its own).
        observedScope?.removeResponder(self)
        observedScope = nil
        if window != nil {
            let scope = ThemeScopeRegistry.resolve(self)
            scope.addResponder(self)
            observedScope = scope
        }
        recolor()
    }

    public func themeDidChange() {
        recolor()
    }

    // visibility-walk-allow: DEBUG gallery host only, shown in the gallery's own window; it recolors one card body as the panel does
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }
}
#endif
