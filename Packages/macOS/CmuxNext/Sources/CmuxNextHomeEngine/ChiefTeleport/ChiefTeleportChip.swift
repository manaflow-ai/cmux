public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// Where the Chief runs, as a small chip (the Home header beside the Chief's name, the Chief card's
/// Runs On row): This Mac, cmux Cloud or the host's name, or the running move's step. A click
/// opens the Teleport menu (``ChiefTeleportMenuBuilder``), whose picks run the app's `chief.moveTo`
/// and `chief.moveRollback` through ``ChiefTeleportModel``.
///
/// It follows ``ChiefTeleportModel/location``, ``ChiefTeleportModel/shownPhase`` (a move the home's
/// hold says runs too) and the fork, and reads the home's
/// marker again each time it joins a window. No animation: each change draws in one frame.
@MainActor
public final class ChiefTeleportChip: NSView {
    /// How it draws (``ChiefTeleportChipStyle/plain`` ships).
    public var style: ChiefTeleportChipStyle { didSet { if style != oldValue { show() } } }
    /// A Chief on another host reads "Chief is on <host>" (Home's header on this Mac's conversation,
    /// which cannot open the Chief there); off, the host's name alone (the Chief card).
    public var saysAway = false { didSet { if saysAway != oldValue { show() } } }
    private let model: ChiefTeleportModel
    private let glyph = ThemedImageView()
    private let label = ThemedLabel(labelWithString: "")
    private let chevron = ThemedImageView()
    private let dot = NSView()
    private lazy var menuBuilder = ChiefTeleportMenuBuilder(model: model)
    private var watch: Task<Void, Never>?
    /// What the chip shows now, decided in ``show()``.
    private var tone = Tone.here

    private enum Tone { case here, away, running, failed }

    static let height: CGFloat = 20
    private static let dotSize: CGFloat = 6
    private static let gap: CGFloat = 4

    /// - Parameters:
    ///   - model: The app's teleport state (or a playground's).
    ///   - style: How it draws.
    public init(model: ChiefTeleportModel, style: ChiefTeleportChipStyle = .plain) {
        self.model = model
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        chevron.image = Self.symbol("chevron.down", scale: .small)
        for view in [glyph, label, chevron, dot] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityIdentifier("cmux.home.chief.teleport")
        setAccessibilityHelp(ChiefTeleportStrings.help)
        show()
        startWatching()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var wantsUpdateLayer: Bool { true }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            watch?.cancel()
            watch = nil
            return
        }
        if watch == nil { startWatching() }
        model.refresh()
    }

    private func startWatching() {
        // task-owner: this view (cancelled when it leaves its window; it ends at the first change after
        // the view is released); event-driven (Observation).
        watch = Task { [weak self, model] in
            for await _ in ObservationStream({ ChiefTeleportChipShown(location: model.location, phase: model.shownPhase, fork: model.marks.fork?.name) }) {
                self?.show()
            }
        }
    }

    // MARK: Drawing

    /// Reads the model and draws the chip for it.
    func show() {
        let phase = model.shownPhase
        let place = Self.placeTitle(model.location, current: model.menu().currentTitle)
        let text: String
        let symbol: String
        switch phase {
        case .checking, .moving, .verifying, .rollingBack:
            tone = .running
            text = ChiefTeleportMenuBuilder.statusLine(phase) ?? place
            symbol = phase == .rollingBack ? "arrow.uturn.backward" : "arrow.triangle.2.circlepath"
        case .failed:
            tone = .failed
            text = ChiefTeleportMenuBuilder.statusLine(phase) ?? place
            symbol = "exclamationmark.triangle"
        case .idle, .done, .rolledBack:
            tone = model.location == .thisMac ? .here : .away
            if saysAway, case .host = model.location {
                text = ChiefTeleportStrings.awayOn(place)
            } else if model.location == .thisMac, model.marks.fork != nil {
                text = ChiefTeleportStrings.withFork(place)
            } else {
                text = place
            }
            symbol = Self.placeSymbol(model.location)
        }
        label.stringValue = text
        label.ink = switch tone {
        case .failed: .danger
        case .here: .secondary
        case .away: style == .plain ? .secondary : .primary
        case .running: .primary
        }
        glyph.image = Self.symbol(symbol, scale: .medium)
        glyph.ink = label.ink
        chevron.ink = .tertiary
        glyph.isHidden = !style.showsGlyph
        label.isHidden = !style.showsText
        chevron.isHidden = !style.showsChevron
        dot.isHidden = style != .dot
        setAccessibilityLabel(ChiefTeleportStrings.label(text))
        themedToolTip = style.showsText ? ChiefTeleportStrings.help : text
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
        superview?.needsLayout = true
    }

    override public func updateLayer() {
        performWithTheme {
            let filled = style == .capsule || (style == .awayBadge && tone != .here)
            layer?.backgroundColor = filled ? (style == .awayBadge ? Palette.selectionFill : Palette.hoverFill).cgColor : nil
            layer?.borderWidth = style == .outline ? 1 : 0
            layer?.borderColor = Palette.separator.cgColor
            let dotColor: NSColor = switch tone {
            case .here: Palette.textTertiary
            case .away, .running: Palette.textPrimary
            case .failed: Palette.danger
            }
            dot.layer?.backgroundColor = dotColor.cgColor
        }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var padding: CGFloat { style == .plain || style == .iconOnly || style == .dot ? 2 : 8 }

    override public var intrinsicContentSize: NSSize {
        var width = padding * 2
        var parts: [CGFloat] = []
        if style == .dot { parts.append(Self.dotSize) }
        if style.showsGlyph { parts.append(glyph.image?.size.width ?? 0) }
        if style.showsText { parts.append(ceil(label.naturalSize.width)) }
        if style.showsChevron { parts.append(chevron.image?.size.width ?? 0) }
        width += parts.reduce(0, +) + Self.gap * CGFloat(max(parts.count - 1, 0))
        return NSSize(width: ceil(width), height: Self.height)
    }

    override public func layout() {
        super.layout()
        var x = padding
        let midY = bounds.midY
        func place(_ view: NSView, width: CGFloat, height: CGFloat) {
            view.frame = NSRect(x: x, y: (midY - height / 2).rounded(), width: width, height: height)
            x += width + Self.gap
        }
        if style == .dot { place(dot, width: Self.dotSize, height: Self.dotSize) }
        if style.showsGlyph, let size = glyph.image?.size { place(glyph, width: size.width, height: size.height) }
        if style.showsText {
            let size = label.naturalSize  // the frame the text needs, its 2 pt side padding included
            let chevronWidth = style.showsChevron ? (chevron.image?.size.width ?? 0) + Self.gap : 0
            place(label, width: max(0, min(ceil(size.width), bounds.width - x - padding - chevronWidth)), height: ceil(size.height))
        }
        if style.showsChevron, let size = chevron.image?.size { place(chevron, width: size.width, height: size.height) }
    }

    // MARK: Menu

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func mouseDown(with event: NSEvent) {
        openMenu()
    }

    override public func accessibilityPerformPress() -> Bool {
        openMenu()
        return true
    }

    /// Pops the Teleport menu up under the chip.
    public func openMenu() {
        let menu = menuBuilder.makeMenu()
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(for: menu, in: self), in: self)
    }

    /// The menu the chip would open now (the playground and tests read it without popping it up).
    public func makeMenu() -> NSMenu { menuBuilder.makeMenu() }

    // MARK: Words and glyphs

    /// The place's words: the menu's name for it (a host's group name), else the chip's own.
    nonisolated static func placeTitle(_ location: ChiefLocation, current: String?) -> String {
        if let current { return current }
        return switch location {
        case .thisMac: ChiefTeleportStrings.thisMac
        case .cloud: ChiefTeleportStrings.cloud
        case .host(let host): host
        }
    }

    static func placeSymbol(_ location: ChiefLocation) -> String {
        switch location {
        case .thisMac: "laptopcomputer"
        case .cloud: "cloud"
        case .host: "macmini"
        }
    }

    private static func symbol(_ name: String, scale: NSImage.SymbolScale) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: TypeScale.caption, weight: TypeScale.regular, scale: scale))
    }
}

/// What the chip follows (one value, so an equal re-read wakes nothing).
private nonisolated struct ChiefTeleportChipShown: Equatable {
    var location: ChiefLocation
    var phase: ChiefTeleportPhase
    var fork: String?
}
