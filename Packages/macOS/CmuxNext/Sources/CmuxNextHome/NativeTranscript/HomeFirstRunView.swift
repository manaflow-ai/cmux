import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// What a first-run row asks the app to do (`HomeNativeTranscriptView.onFirstRunAction`).
public enum HomeFirstRunAction: Sendable, Equatable {
    /// A new terminal tab (the sidebar's New Terminal Tab, `newSurface`).
    case openTerminal
    /// A new agent chat (`palette.newAgentChat`).
    case startAgent
}

/// The empty Chief conversation's first-run panel: things to do now, each a
/// row with its shortcut (open a terminal, start an agent), then the user's
/// agents at a glance, most urgent first, each opening its tab, then a
/// one-line keyboard hint. Labels and actions only, no lines about what the
/// Chief is. Hidden once the conversation has a message
/// (`HomeNativeTranscriptView.updateFirstRun`).
final class HomeFirstRunView: NSView {
    let terminal = HomeFirstRunRow(title: HomeStrings.firstRunOpenTerminal, icon: .terminalNew)
    let agent = HomeFirstRunRow(title: HomeStrings.firstRunStartAgent, icon: .agentChat)
    /// "Your agents", over the agent rows; out of the stack with no agents.
    let agentsHeader = NSTextField(labelWithString: HomeStrings.firstRunAgentsHeader)
    /// One row per listed agent (`setAgents`), the status word at the trailing edge.
    private(set) var agentRows: [HomeFirstRunRow] = []
    private(set) var agents: [HomeAgentGlance] = []
    let hint = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var scale: CGFloat = 1
    private var colors: Colors?
    private lazy var headerWidth = agentsHeader.widthAnchor.constraint(equalToConstant: Self.maxWidth)
    /// Called when the user picks open a terminal or start an agent.
    var onAction: (HomeFirstRunAction) -> Void = { _ in }
    /// Called with an agent's tab id when the user picks its row.
    var onAgent: (String) -> Void = { _ in }

    static let maxWidth: CGFloat = 340

    var rows: [HomeFirstRunRow] { [terminal, agent] + agentRows }

    /// The theme's colours, kept for agent rows made after the last theme pass.
    private struct Colors {
        var primary, tertiary, fill, hover, border, attention, danger, done: NSColor
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hint.font = Typography.style(.body).font
        hint.alignment = .center
        hint.isSelectable = false
        hint.isHidden = true
        agentsHeader.font = Typography.style(.bodyEmphasized).font
        agentsHeader.isSelectable = false
        agentsHeader.lineBreakMode = .byTruncatingTail
        agentsHeader.setAccessibilityRole(.staticText)
        headerWidth.isActive = true
        terminal.onClick = { [weak self] in self?.onAction(.openTerminal) }
        agent.onClick = { [weak self] in self?.onAction(.startAgent) }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.stackGap
        arrange()
        addSubview(stack)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

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
        for view in [terminal, agent] + listed + [hint] as [NSView] { stack.addArrangedSubview(view) }
        applySpacing()
    }

    /// Lists only the agent rows that fit above the field, dropping the
    /// least urgent first (and the heading with the last one): the panel
    /// never runs under the compose field. Measured from the rows' fixed
    /// heights, and a row's `isHidden` changes only when the count that fits
    /// does (hidden arranged views leave the stack's layout).
    private func fitAgentRows() {
        let row = HomeFirstRunRow.height * scale, gap = Metrics.stackGap, group = Metrics.sectionGap + Metrics.space1
        let hint = self.hint.isHidden ? 0 : group + ceil(self.hint.intrinsicContentSize.height)
        let base = 2 * row + gap + hint
        let header = group + ceil(agentsHeader.intrinsicContentSize.height)
        var shown = agentRows.count
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
        stack.spacing = Metrics.stackGap
        stack.setCustomSpacing(Metrics.sectionGap + Metrics.space1, after: agent)
    }

    /// Applies the live interface scale to this native empty state.
    func applyScale(_ scale: CGFloat) {
        guard self.scale != scale else { return }
        self.scale = scale
        hint.font = Typography.style(.body).font
        agentsHeader.font = Typography.style(.bodyEmphasized).font
        applySpacing()
        for row in rows { row.applyScale(scale) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The rows' shortcuts and the tab hint's keys, as the registry shows
    /// them (cmux.json overrides included); nil hides one.
    func setShortcuts(terminal: String?, agent: String?, tabs: String?) {
        self.terminal.shortcut = terminal
        self.agent.shortcut = agent
        hint.stringValue = tabs.map(HomeStrings.firstRunTabsHint) ?? ""
        hint.isHidden = tabs == nil
        needsLayout = true
    }

    /// Colours from the theme (caller runs inside `performWithTheme`): text
    /// tiers, the rows' raised fill, hover fill and hairline, and the status
    /// words' colours (needs you, failed, done; the rest stay quiet).
    func applyColors(primary: NSColor, tertiary: NSColor, fill: NSColor, hover: NSColor, border: NSColor,
                     attention: NSColor, danger: NSColor, done: NSColor) { // theme-scoped
        colors = Colors(primary: primary, tertiary: tertiary, fill: fill, hover: hover, border: border,
                        attention: attention, danger: danger, done: done)
        applyStoredColors()
    }

    private func applyStoredColors() {
        guard let colors else { return }
        hint.textColor = colors.tertiary
        agentsHeader.textColor = colors.tertiary
        for row in [terminal, agent] {
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
        fitAgentRows()
        let size = stack.fittingSize
        stack.frame = CGRect(x: (bounds.width - width) / 2, y: max(0, (bounds.height - size.height) / 2),
                             width: width, height: size.height)
    }
}

/// One first-run row: a glyph, a label and the action's shortcut on a raised
/// small-radius rect with a hairline (never a capsule), taking the hover
/// fill under the pointer. A bezel NSButton draws gray when the window is
/// not key and reads as disabled. Clicks, VoiceOver's press, and Return or Space while it has
/// keyboard focus run `onClick`; Tab reaches it and Up and Down move between the rows.
final class HomeFirstRunRow: NSView {
    let surface = NSView()
    let glyph = NSImageView()
    let label: NSTextField
    /// The row's cmux icon.
    let icon: IconName
    let shortcutLabel = NSTextField(labelWithString: "")
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
        label = NSTextField(labelWithString: title)
        self.icon = icon
        super.init(frame: .zero)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        addSubview(surface)
        glyph.image = NSImage.icon(icon, size: .iconRowSize(forLabelPointSize: Typography.message.pointSize))
        glyph.imageScaling = .scaleProportionallyDown
        label.font = Typography.style(.message).font
        label.lineBreakMode = .byTruncatingTail
        shortcutLabel.font = Typography.style(.body).font
        shortcutLabel.alignment = .right
        shortcutLabel.isHidden = true
        for view in [glyph, label, activity, shortcutLabel] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: Self.height * scale) }

    /// Applies the live interface scale to the row's type, icon and geometry.
    func applyScale(_ scale: CGFloat) {
        self.scale = scale
        surface.layer?.cornerRadius = Self.cornerRadius * scale
        glyph.image = NSImage.icon(icon, size: .iconRowSize(forLabelPointSize: Typography.message.pointSize))
        label.font = Typography.style(.message).font
        shortcutLabel.font = Typography.style(.body).font
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
        let inset = Metrics.space5
        let side = CGFloat.iconRowSize(forLabelPointSize: Typography.message.pointSize)
        glyph.frame = CGRect(x: inset, y: (bounds.height - side) / 2, width: side, height: side)
        let shortcutWidth = shortcutLabel.isHidden ? 0 : ceil(shortcutLabel.attributedStringValue.size().width) + Metrics.space2
        let shortcutHeight = ceil(shortcutLabel.intrinsicContentSize.height)
        shortcutLabel.frame = CGRect(x: bounds.width - inset - shortcutWidth, y: (bounds.height - shortcutHeight) / 2,
                                     width: shortcutWidth, height: shortcutHeight)
        let indicator = Typography.message.pointSize
        activity.frame = CGRect(x: shortcutLabel.frame.minX - indicator - Metrics.space2, y: (bounds.height - indicator) / 2,
                                width: indicator, height: indicator)
        let trailing = activity.showsGlyph ? activity.frame.minX : shortcutLabel.frame.minX
        let textX = glyph.frame.maxX + Metrics.space4 + Metrics.space1
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: textX, y: (bounds.height - textHeight) / 2,
                             width: max(0, trailing - Metrics.space4 - textX), height: textHeight)
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
