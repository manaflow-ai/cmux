import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// What a first-run row asks the app to do (`HomeNativeTranscriptView.onFirstRunAction`).
public enum HomeFirstRunAction: Sendable, Equatable {
    /// A new terminal tab (the sidebar's New Terminal Tab, `newSurface`).
    case openTerminal
    /// A new agent chat (`palette.newAgentChat`).
    case startAgent
    /// Show or hide the floating Chief pet (`home.toggleChiefPet`).
    case togglePet
    /// Bring memory from other tools found on this Mac (`chief.importMemories`).
    case importMemories
}

/// The empty Chief conversation's first-run panel, the Chief's front page: the Chief's face
/// and what it does (`HomeFirstRunHero`), then things to do now, each a row with its shortcut
/// (start an agent, open a terminal) and the Chief pet's Show / Hide, then the user's agents
/// at a glance, most urgent first, each opening its tab, then the "Switching" card with the
/// core switching keys (`HomeFirstRunSwitchCard`, hidden for good by its Hide button). Hidden
/// once the conversation has a message (`HomeNativeTranscriptView.updateFirstRun`). A short
/// pane drops agent rows first, then the hero.
final class HomeFirstRunView: NSView {
    let terminal = HomeFirstRunRow(title: HomeStrings.firstRunOpenTerminal, icon: .terminalNew)
    let agent = HomeFirstRunRow(title: HomeStrings.firstRunStartAgent, icon: .agentChat)
    /// Show Chief Pet, or Hide Chief Pet while it shows (`setPetShown`).
    let pet = HomeFirstRunRow(title: HomeStrings.firstRunShowPet, icon: .agentChief)
    /// "Bring your memory from Claude Code and ChatGPT": in the panel only while the host offers it (`setMemoryOffer`).
    let memory = HomeFirstRunRow(title: "", icon: .actionDownload)
    private(set) var memoryOffer: String?
    /// The Chief's face and what it does; out of the layout when the tunable hides it or it does not fit.
    let hero = HomeFirstRunHero()
    private lazy var heroHeight = hero.heightAnchor.constraint(equalToConstant: 0)
    private lazy var heroWidth = hero.widthAnchor.constraint(equalToConstant: Self.maxWidth)
    /// `HomeTunables.firstRunHero`: false keeps the rows-only panel.
    var showsHero = true { didSet { if showsHero != oldValue { needsLayout = true } } }
    /// "Your agents", over the agent rows; out of the stack with no agents.
    let agentsHeader = ChromeLabel(labelWithString: HomeStrings.firstRunAgentsHeader)
    /// One row per listed agent (`setAgents`), the status word at the trailing edge.
    private(set) var agentRows: [HomeFirstRunRow] = []
    private(set) var agents: [HomeAgentGlance] = []
    /// The core switching keys; out of the layout while hidden.
    let switchCard = HomeFirstRunSwitchCard()
    private lazy var cardHeight = switchCard.heightAnchor.constraint(equalToConstant: 0)
    private lazy var cardWidth = switchCard.widthAnchor.constraint(equalToConstant: Self.maxWidth)
    private let stack = NSStackView()
    private var scale: CGFloat = 1
    private var colors: Colors?
    private lazy var headerWidth = agentsHeader.widthAnchor.constraint(equalToConstant: Self.maxWidth)
    /// Called when the user picks open a terminal or start an agent.
    var onAction: (HomeFirstRunAction) -> Void = { _ in }
    /// Called with an agent's tab id when the user picks its row.
    var onAgent: (String) -> Void = { _ in }

    static let maxWidth: CGFloat = 340

    var rows: [HomeFirstRunRow] { actionRows + agentRows }
    /// The action rows, in panel order.
    var actionRows: [HomeFirstRunRow] { memoryOffer == nil ? [agent, terminal, pet] : [agent, terminal, memory, pet] }

    /// The theme's colours, kept for agent rows made after the last theme pass.
    private struct Colors {
        var primary, secondary, tertiary, fill, hover, border, attention, danger, done: NSColor
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        switchCard.isHidden = true
        switchCard.translatesAutoresizingMaskIntoConstraints = false
        cardHeight.isActive = true
        cardWidth.isActive = true
        hero.translatesAutoresizingMaskIntoConstraints = false
        heroHeight.isActive = true
        heroWidth.isActive = true
        agentsHeader.font = .systemFont(ofSize: 12, weight: .medium)
        agentsHeader.isSelectable = false
        agentsHeader.lineBreakMode = .byTruncatingTail
        agentsHeader.setAccessibilityRole(.staticText)
        headerWidth.isActive = true
        terminal.onClick = { [weak self] in self?.onAction(.openTerminal) }
        agent.onClick = { [weak self] in self?.onAction(.startAgent) }
        pet.onClick = { [weak self] in self?.onAction(.togglePet) }
        memory.onClick = { [weak self] in self?.onAction(.importMemories) }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        arrange()
        addSubview(stack)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// The agents to list: at most five, most urgent first. No agents, no
    /// list. Rows are rebuilt only when what they show changed.
    func setAgents(_ list: [HomeAgentGlance]) {
        let shown = HomeAgentGlance.shortlist(list)
        guard shown != agents else { return }
        // A rebuild drops the old rows; keep keyboard focus on the same agent, or the column.
        let focused = zip(agents, agentRows).first { window?.firstResponder === $0.1 }?.0.id
        agents = shown
        agentRows = shown.map { glance in
            let row = HomeFirstRunRow(title: glance.title, icon: glance.icon)
            // The status word is the row's trailing text and VoiceOver's value, not a shortcut.
            let word = HomeStrings.firstRunAgentStatus(glance.status)
            row.shortcut = word
            row.activity.configure(glance.indicator, style: glance.indicatorStyle)
            row.setAccessibilityHelp(nil)
            row.setAccessibilityValue(word)
            row.applyScale(scale)
            let id = glance.id
            row.onClick = { [weak self] in self?.onAgent(id) }
            return row
        }
        arrange()
        applyStoredColors()
        needsLayout = true
        if let focused {
            window?.makeFirstResponder(zip(shown, agentRows).first { $0.0.id == focused }?.1 ?? agent)
        }
    }

    /// The stack's views in order, with the gaps between groups.
    private func arrange() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let listed: [NSView] = agentRows.isEmpty ? [] : [agentsHeader] + agentRows
        for view in [hero] + actionRows + listed + [switchCard] as [NSView] { stack.addArrangedSubview(view) }
        applySpacing()
    }

    /// Shows only what fits above the field, so the panel never runs under
    /// the compose field (a long draft grows it up into the panel): agent
    /// rows go first, least urgent first (the heading with the last one),
    /// then the hero, then the Switching card, then the action rows together.
    /// Measured from the parts' fixed heights, and a view's `isHidden`
    /// changes only when what fits does (hidden arranged views leave the
    /// stack's layout).
    private func fitAgentRows() {
        let row = HomeFirstRunRow.height * scale, gap = 6 * scale, group = 14 * scale
        let actions = CGFloat(actionRows.count) * row + CGFloat(actionRows.count - 1) * gap
        let actionsFit = actions <= bounds.height
        if stack.isHidden != !actionsFit { stack.isHidden = !actionsFit }
        // The card's keys are set (Hide clears them); it shows when it fits under the rows.
        let cardPart = group + cardHeight.constant
        let wantsCard = !switchCard.lineViews.isEmpty
        let cardFits = wantsCard && actionsFit && actions + cardPart <= bounds.height
        if switchCard.isHidden != !cardFits { switchCard.isHidden = !cardFits }
        let card = cardFits ? cardPart : 0
        // The hero goes before the card or any action row does: it shows only when it fits with
        // them, and only while a card that has keys still shows (a tall card can outsize it).
        let heroPart = heroHeight.constant + Self.heroGap * scale
        let heroFits = showsHero && actionsFit && cardFits == wantsCard && actions + card + heroPart <= bounds.height
        if hero.isHidden != !heroFits { hero.isHidden = !heroFits }
        let base = actions + card + (heroFits ? heroPart : 0)
        let header = group + ceil(agentsHeader.intrinsicContentSize.height)
        // Agent rows go first: none while the hero or the card it wants has gone.
        var shown = heroFits == showsHero && cardFits == wantsCard ? agentRows.count : 0
        while shown > 0, base + header + CGFloat(shown) * (gap + row) > bounds.height { shown -= 1 }
        for (index, view) in agentRows.enumerated() where view.isHidden != (index >= shown) { view.isHidden = index >= shown }
        if agentsHeader.isHidden != (shown == 0) { agentsHeader.isHidden = shown == 0 }
        // The group gap follows the last listed row; set only on change.
        for (index, view) in agentRows.enumerated() {
            let spacing = index == shown - 1 ? group : NSStackView.useDefaultSpacing
            if stack.customSpacing(after: view) != spacing { stack.setCustomSpacing(spacing, after: view) }
        }
    }

    private func applySpacing() {
        stack.spacing = 6 * scale
        stack.setCustomSpacing(14 * scale, after: pet)
        stack.setCustomSpacing(Self.heroGap * scale, after: hero)
    }

    /// The space between the hero and the first row.
    static let heroGap: CGFloat = 20

    /// Shows the memory row with `title` ("Bring your memory from Claude Code"), or removes it (nil).
    func setMemoryOffer(_ title: String?) {
        guard title != memoryOffer else { return }
        memoryOffer = title
        if let title {
            memory.label.stringValue = title
            memory.setAccessibilityLabel(title)
            memory.applyScale(scale)
        }
        arrange()
        applyStoredColors()
        needsLayout = true
    }

    /// The pet row reads as the change it makes: Hide Chief Pet while the pet shows.
    func setPetShown(_ shown: Bool) {
        let title = shown ? HomeStrings.firstRunHidePet : HomeStrings.firstRunShowPet
        guard pet.title != title else { return }
        pet.label.stringValue = title
        pet.setAccessibilityLabel(title)
        pet.needsLayout = true
    }

    /// Applies the live interface scale to this native empty state.
    func applyScale(_ scale: CGFloat) {
        guard self.scale != scale else { return }
        self.scale = scale
        switchCard.applyScale(scale)
        hero.applyScale(scale)
        agentsHeader.font = .systemFont(ofSize: 12 * scale, weight: .medium)
        applySpacing()
        for row in rows { row.applyScale(scale) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The rows' shortcuts and the Switching card's keys, as the live
    /// binding table has them (cmux.json and keybindings.json included); nil
    /// hides a row's shortcut, nil `switching` hides the card.
    func setShortcuts(terminal: String?, agent: String?, switching: HomeSwitchKeys?) {
        self.terminal.shortcut = terminal
        self.agent.shortcut = agent
        switchCard.apply(switching)
        needsLayout = true
    }

    /// Colours from the theme (caller runs inside `performWithTheme`): text
    /// tiers, the rows' raised fill, hover fill and hairline, and the status
    /// words' colours (needs you, failed, done; the rest stay quiet).
    func applyColors(primary: NSColor, secondary: NSColor, tertiary: NSColor, fill: NSColor, hover: NSColor, border: NSColor,
                     attention: NSColor, danger: NSColor, done: NSColor) { // theme-scoped
        colors = Colors(primary: primary, secondary: secondary, tertiary: tertiary, fill: fill, hover: hover, border: border,
                        attention: attention, danger: danger, done: done)
        applyStoredColors()
    }

    private func applyStoredColors() {
        guard let colors else { return }
        switchCard.applyColors(primary: colors.primary, tertiary: colors.tertiary, fill: colors.fill, border: colors.border)
        agentsHeader.textColor = colors.tertiary
        hero.applyColors(primary: colors.primary, secondary: colors.secondary)
        for row in actionRows {
            row.applyColors(text: colors.primary, quiet: colors.tertiary, fill: colors.fill, hover: colors.hover, border: colors.border)
        }
        for (row, glance) in zip(agentRows, agents) {
            let word: NSColor = switch glance.status {
            case .needsYou: colors.attention
            case .failed: colors.danger
            case .done: colors.done
            case .idle, .working: colors.tertiary
            }
            row.applyColors(text: colors.primary, quiet: word, fill: colors.fill, hover: colors.hover, border: colors.border)
        }
    }

    override func layout() {
        super.layout()
        let width = max(0, min(Self.maxWidth * scale, bounds.width - 48 * scale))
        for row in rows { row.width = width }
        if headerWidth.constant != width { headerWidth.constant = width }
        if cardWidth.constant != width { cardWidth.constant = width }
        if heroWidth.constant != width { heroWidth.constant = width }
        let heroTall = hero.height(for: width)
        if heroHeight.constant != heroTall { heroHeight.constant = heroTall }
        let card = switchCard.height(for: width)
        if cardHeight.constant != card { cardHeight.constant = card }
        fitAgentRows()
        let size = stack.fittingSize
        stack.frame = CGRect(x: (bounds.width - width) / 2, y: max(0, (bounds.height - size.height) / 2),
                             width: width, height: size.height)
    }
}

/// One first-run row: a glyph, a label and the action's shortcut on a raised
/// small-radius rect with a hairline (never a capsule), taking the hover
/// fill under the pointer. A bezel NSButton draws gray when the window is
/// not key and reads as disabled. Clicks, VoiceOver's press, and Return while it has keyboard
/// focus run `onClick`; Space is printable input routed to the Home message box. Tab reaches it
/// and Up and Down move between the rows.
final class HomeFirstRunRow: NSView {
    let surface = NSView()
    let glyph = NSImageView()
    let label: ChromeLabel
    /// The row's cmux icon.
    let icon: IconName
    let shortcutLabel = ChromeLabel(labelWithString: "")
    /// An agent row's state in the shared indicator, before its status word.
    let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.tracksWindowOcclusion = true; return view }()
    var onClick: () -> Void = {}
    var title: String { label.stringValue }
    /// The row's width (the panel's column).
    var width: CGFloat = 300 { didSet { if width != oldValue { invalidateIntrinsicContentSize() } } }
    /// The action's shortcut, drawn at the trailing edge; nil draws none.
    var shortcut: String? {
        didSet {
            shortcutLabel.stringValue = shortcut ?? ""
            shortcutLabel.isHidden = shortcut == nil
            setAccessibilityHelp(shortcut)
            needsLayout = true
        }
    }

    static let height: CGFloat = 28
    static let cornerRadius: CGFloat = 8
    private var scale: CGFloat = 1
    private var fill = NSColor.clear
    private var hoverFill = NSColor.clear
    private var isHovered = false { didSet { if isHovered != oldValue { paint() } } }

    init(title: String, icon: IconName) {
        label = ChromeLabel(labelWithString: title)
        self.icon = icon
        super.init(frame: .zero)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        addSubview(surface)
        glyph.image = NSImage.icon(icon, size: .iconRowSize(forLabelPointSize: 13))
        glyph.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.alignment = .right
        shortcutLabel.isHidden = true
        for view in [glyph, label, activity, shortcutLabel] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: Self.height * scale) }

    /// Applies the live interface scale to the row's type, icon and geometry.
    func applyScale(_ scale: CGFloat) {
        self.scale = scale
        surface.layer?.cornerRadius = Self.cornerRadius * scale
        glyph.image = NSImage.icon(icon, size: .iconRowSize(forLabelPointSize: 13 * scale))
        label.font = .systemFont(ofSize: 13 * scale)
        shortcutLabel.font = .systemFont(ofSize: 12 * scale)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Colours from the theme (caller runs inside `performWithTheme`).
    func applyColors(text: NSColor, quiet: NSColor, fill: NSColor, hover: NSColor, border: NSColor) { // theme-scoped
        label.textColor = text
        glyph.contentTintColor = text
        shortcutLabel.textColor = quiet
        self.fill = fill
        // The hover token is translucent: composite it over the raised fill.
        hoverFill = fill.blended(withFraction: hover.alphaComponent, of: hover.withAlphaComponent(1)) ?? fill
        surface.layer?.borderColor = border.cgColor
        paint()
    }

    private func paint() {
        surface.layer?.backgroundColor = (isHovered ? hoverFill : fill).cgColor
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let inset: CGFloat = 12 * scale
        let side = CGFloat.iconRowSize(forLabelPointSize: 13 * scale)
        glyph.frame = CGRect(x: inset, y: (bounds.height - side) / 2, width: side, height: side)
        let shortcutWidth = shortcutLabel.isHidden ? 0 : ceil(shortcutLabel.attributedStringValue.size().width) + 4
        let shortcutHeight = ceil(shortcutLabel.intrinsicContentSize.height)
        shortcutLabel.frame = CGRect(x: bounds.width - inset - shortcutWidth, y: (bounds.height - shortcutHeight) / 2,
                                     width: shortcutWidth, height: shortcutHeight)
        let indicator: CGFloat = 13 * scale
        activity.frame = CGRect(x: shortcutLabel.frame.minX - indicator - 4 * scale, y: (bounds.height - indicator) / 2,
                                width: indicator, height: indicator)
        let trailing = activity.showsGlyph ? activity.frame.minX : shortcutLabel.frame.minX
        let textX = glyph.frame.maxX + 10 * scale
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: textX, y: (bounds.height - textHeight) / 2,
                             width: max(0, trailing - 8 * scale - textX), height: textHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = Self.cornerRadius * scale
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return super.keyDown(with: event) }
        // Return only: Home sends printable keys, Space included, to the message box first.
        switch event.keyCode {
        case 36, 76: if !event.isARepeat { onClick() } // Return, keypad Enter
        case 125: focusSibling(by: 1) // Down
        case 126: focusSibling(by: -1) // Up
        default: super.keyDown(with: event)
        }
    }

    /// Moves keyboard focus to the previous or next first-run row in the same column.
    private func focusSibling(by step: Int) {
        let rows = superview?.subviews.compactMap { $0 as? HomeFirstRunRow }.filter { !$0.isHiddenOrHasHiddenAncestor } ?? []
        guard let index = rows.firstIndex(where: { $0 === self }), rows.indices.contains(index + step) else { return }
        window?.makeFirstResponder(rows[index + step])
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    func performClick(_ sender: Any?) { onClick() }
}
