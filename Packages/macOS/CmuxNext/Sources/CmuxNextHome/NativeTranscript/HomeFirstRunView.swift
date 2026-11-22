import AppKit
import CmuxNextIcons

/// What a first-run row asks the app to do (`HomeNativeTranscriptView.onFirstRunAction`).
public enum HomeFirstRunAction: Sendable, Equatable {
    /// A new terminal tab (the sidebar's New Terminal Tab, `newSurface`).
    case openTerminal
    /// A new agent chat (`palette.newAgentChat`).
    case startAgent
}

/// The empty Chief conversation's first-run panel: things to do now, each a
/// row with its shortcut: open a terminal, start an agent, or ask the Chief
/// (which fills the field, never sends), then a one-line keyboard hint.
/// Labels and actions only, no lines about what the Chief is. Hidden once
/// the conversation has a message (`HomeNativeTranscriptView.updateFirstRun`).
final class HomeFirstRunView: NSView {
    let terminal = HomeFirstRunRow(title: HomeStrings.firstRunOpenTerminal, icon: .terminalNew)
    let agent = HomeFirstRunRow(title: HomeStrings.firstRunStartAgent, icon: .agentChat)
    let suggestion = HomeFirstRunRow(title: HomeStrings.firstRunSuggestion, icon: .agentQuestion)
    let hint = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var scale: CGFloat = 1
    /// Called with the suggested prompt when the user clicks it.
    var onSuggestion: (String) -> Void = { _ in }
    /// Called when the user picks open a terminal or start an agent.
    var onAction: (HomeFirstRunAction) -> Void = { _ in }

    static let maxWidth: CGFloat = 340

    var rows: [HomeFirstRunRow] { [terminal, agent, suggestion] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hint.font = .systemFont(ofSize: 12)
        hint.alignment = .center
        hint.isSelectable = false
        hint.isHidden = true
        terminal.onClick = { [weak self] in self?.onAction(.openTerminal) }
        agent.onClick = { [weak self] in self?.onAction(.startAgent) }
        suggestion.onClick = { [weak self] in self?.suggest() }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        for view in rows + [hint] as [NSView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(14, after: suggestion)
        addSubview(stack)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private func suggest() { onSuggestion(suggestion.title) }

    /// Applies the live interface scale to this native empty state.
    func applyScale(_ scale: CGFloat) {
        guard self.scale != scale else { return }
        self.scale = scale
        hint.font = .systemFont(ofSize: 12 * scale)
        stack.spacing = 6 * scale
        stack.setCustomSpacing(14 * scale, after: suggestion)
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
    /// tiers, and the rows' raised fill, hover fill and hairline.
    func applyColors(primary: NSColor, secondary: NSColor, tertiary: NSColor, fill: NSColor, hover: NSColor,
                     border: NSColor) { // theme-scoped
        hint.textColor = tertiary
        for row in rows { row.applyColors(text: primary, quiet: tertiary, fill: fill, hover: hover, border: border) }
    }

    override func layout() {
        super.layout()
        let width = min(Self.maxWidth * scale, bounds.width - 48 * scale)
        for row in rows { row.width = width }
        let size = stack.fittingSize
        stack.frame = CGRect(x: (bounds.width - width) / 2, y: max(0, (bounds.height - size.height) / 2),
                             width: width, height: size.height)
    }
}

/// One first-run row: a glyph, a label and the action's shortcut on a raised
/// small-radius rect with a hairline (never a capsule), taking the hover
/// fill under the pointer. A bezel NSButton draws gray when the window is
/// not key and reads as disabled. Clicks and VoiceOver's press run `onClick`.
final class HomeFirstRunRow: NSView {
    let surface = NSView()
    let glyph = NSImageView()
    let label: NSTextField
    /// The row's cmux icon.
    let icon: IconName
    let shortcutLabel = NSTextField(labelWithString: "")
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

    static let height: CGFloat = 34
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
        glyph.image = NSImage.icon(icon, size: .iconRowSize(forLabelPointSize: 13))
        glyph.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.alignment = .right
        shortcutLabel.isHidden = true
        for view in [glyph, label, shortcutLabel] { addSubview(view) }
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
        let textX = glyph.frame.maxX + 10 * scale
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: textX, y: (bounds.height - textHeight) / 2,
                             width: max(0, shortcutLabel.frame.minX - 8 * scale - textX), height: textHeight)
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

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    func performClick(_ sender: Any?) { onClick() }
}
