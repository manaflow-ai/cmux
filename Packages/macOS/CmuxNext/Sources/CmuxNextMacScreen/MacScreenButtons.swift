import AppKit
import CmuxNextDesign

/// A button in the theme: `primary` is the accent fill (the default action),
/// `plain` a faint fill, `destructive` the danger color, `icon` a bare glyph
/// that fills on hover. A `hint` draws the key that presses it after the
/// title and binds that key (u2647), as `CmuxDialogActionButton` did.
@MainActor
final class MacScreenButton: NSButton, MacScreenInked {
    enum Role {
        case primary
        case plain
        case destructive
        case icon
    }

    let role: Role
    let compact: Bool
    let hint: CmuxDialogKeyHint?
    private let text: String
    private let symbol: String?
    private let onPress: () -> Void
    private var colors = MacScreenColors()
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    private var tracking: NSTrackingArea?

    init(_ title: String, role: Role = .plain, compact: Bool = false, hint: CmuxDialogKeyHint? = nil, symbol: String? = nil,
         id: String? = nil, action: @escaping () -> Void) {
        self.role = role
        self.compact = compact
        self.hint = hint
        text = title
        self.symbol = symbol
        onPress = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerCurve = .continuous
        target = self
        self.action = #selector(pressed)
        if let hint {
            keyEquivalent = hint.keyEquivalent
            keyEquivalentModifierMask = hint.modifierMask
        }
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageOnly
            self.title = ""
        }
        setContentHuggingPriority(.required, for: .horizontal)
        // Just under required: a long localized title truncates instead of breaking a fixed-width card.
        setContentCompressionResistancePriority(.init(999), for: .horizontal)
        setAccessibilityLabel(title)
        setAccessibilityHelp(hint?.spokenName)
        if let id { setAccessibilityIdentifier(id) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed() {
        onPress()
    }

    /// The first click in an inactive window (the approval panel over another app) presses it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isEnabled: Bool { didSet { refresh() } }
    override var isHighlighted: Bool { didSet { refresh() } }

    /// The key presses this button only while the keyboard is in its tab: Return typed into
    /// another pane of the window never presses a Mac Screen card's button.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hint != nil, let window, let scope = keyScope else { return super.performKeyEquivalent(with: event) }
        guard let focused = window.firstResponder as? NSView, focused.isDescendant(of: scope) || scope.isDescendant(of: focused) else {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The Mac Screen tab or screen this button sits in.
    private var keyScope: NSView? {
        var view = superview
        while let candidate = view {
            if candidate is MacScreenPaneView || candidate is MacScreenTabView { return candidate }
            view = candidate.superview
        }
        return nil
    }

    func apply(_ colors: MacScreenColors) {
        self.colors = colors
        refresh()
    }

    /// Draws the title at the type scale's size now (a button made once, in the toolbar).
    func reloadType() { refresh() }

    private var labelFont: NSFont { role == .primary ? MacScreenType.emphasized : MacScreenType.body }
    private var horizontalPadding: CGFloat { role == .icon ? Metrics.space1 : (compact ? Metrics.space3 : Metrics.space4) }
    private var minHeight: CGFloat { compact || role == .icon ? 22 : 26 }

    override var intrinsicContentSize: NSSize {
        let content: NSSize
        if let image {
            content = image.size
        } else {
            content = attributedTitle.size()
        }
        var width = ceil(content.width) + horizontalPadding * 2
        if role == .icon { width = max(width, Metrics.space6) }
        return NSSize(width: width, height: max(minHeight, ceil(content.height)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovering = false }
    }

    private var foreground: NSColor {
        switch role {
        case .primary: colors.onAccent
        case .destructive: colors.danger
        case .plain: colors.primary
        case .icon: hovering ? colors.primary : colors.secondary
        }
    }

    private var fill: NSColor {
        let pressed = isHighlighted
        switch role {
        case .primary: return colors.accent.withAlphaComponent(colors.accent.alphaComponent * (pressed ? 0.75 : (hovering ? 0.9 : 1)))
        case .icon: return pressed ? colors.pressed : (hovering && isEnabled ? colors.hover : .clear)
        case .plain, .destructive: return pressed ? colors.pressed : (hovering ? colors.selection : colors.hover)
        }
    }

    private func refresh() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = Metrics.itemCornerRadius
        alphaValue = isEnabled ? 1 : 0.45
        let color = foreground
        if symbol != nil {
            symbolConfiguration = NSImage.SymbolConfiguration(pointSize: labelFont.pointSize, weight: .regular)
            contentTintColor = color
        } else {
            attributedTitle = title(color: color)
        }
        invalidateIntrinsicContentSize()
    }

    /// The title, then the key that presses it, smaller and fainter (SwiftUI's `.secondary` of the label's ink).
    private func title(color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let label = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key.foregroundColor: color,
            NSAttributedString.Key.font: labelFont,
            NSAttributedString.Key.paragraphStyle: paragraph,
        ])
        guard let hint else { return label }
        let caption = MacScreenType.caption
        label.append(NSAttributedString(string: " " + hint.glyph, attributes: [
            NSAttributedString.Key.foregroundColor: color.withAlphaComponent(color.alphaComponent * 0.5),
            NSAttributedString.Key.font: caption,
            NSAttributedString.Key.paragraphStyle: paragraph,
        ]))
        // The gap between the title and its key: `Metrics.space2`, not a space's width.
        let space: CGFloat = NSAttributedString(string: " ", attributes: [NSAttributedString.Key.font: caption]).size().width
        let kern: CGFloat = max(0, Metrics.space2 - space)
        label.addAttribute(NSAttributedString.Key.kern, value: NSNumber(value: Double(kern)),
                           range: NSRange(location: (text as NSString).length, length: 1))
        return label
    }
}

/// A menu's button: its glyph (and title) in an ink, no fill, the menu below
/// it on a click, Space or an accessibility press. The menu is made when it
/// opens, so its checkmarks are current.
@MainActor
final class MacScreenMenuButton: NSButton, MacScreenInked {
    var ink: KeyPath<MacScreenColors, NSColor> {
        didSet { refresh() }
    }
    var makeMenu: () -> NSMenu = { NSMenu() }
    private var label: String?
    private var colors = MacScreenColors()

    init(symbol: String, title: String? = nil, accessibilityTitle: String?, ink: KeyPath<MacScreenColors, NSColor> = \.secondary, id: String) {
        self.ink = ink
        label = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityTitle)
        imagePosition = title == nil ? .imageOnly : .imageLeading
        imageHugsTitle = true
        target = self
        action = #selector(open)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.menuButton)
        // nil: the symbol's own description, as SwiftUI read it.
        if let accessibilityTitle { setAccessibilityLabel(accessibilityTitle) }
        setAccessibilityIdentifier(id)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ colors: MacScreenColors) {
        self.colors = colors
        refresh()
    }

    /// Draws the glyph and title at the type scale's size now.
    func reloadType() { refresh() }

    func retitle(_ title: String) {
        guard label != nil, title != label else { return }
        label = title
        setAccessibilityLabel(title)
        refresh()
    }

    private func refresh() {
        let color = colors[keyPath: ink]
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: MacScreenType.body.pointSize, weight: .regular)
        contentTintColor = color
        if let label {
            attributedTitle = NSAttributedString(string: label, attributes: [.foregroundColor: color, .font: MacScreenType.body])
        } else {
            title = ""
        }
        invalidateIntrinsicContentSize()
    }

    @objc private func open() {
        let menu = makeMenu()
        menu.appearance = effectiveAppearance
        menu.font = MacScreenType.body
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 4 : -4), in: self)
    }
}

/// What a Mac Screen menu row runs (a person's choice); the row keeps it as its represented object.
final class MacScreenMenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
        super.init()
    }

    @objc func choose(_ sender: Any?) {
        run()
    }
}

extension NSMenuItem {
    /// A Mac Screen menu row that runs `run` when chosen.
    static func macScreen(_ title: String, checked: Bool = false, run: @escaping () -> Void) -> NSMenuItem {
        let action = MacScreenMenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MacScreenMenuAction.choose(_:)), keyEquivalent: "")
        // The target is weak: the row holds its action.
        item.representedObject = action
        item.target = action
        item.state = checked ? .on : .off
        return item
    }
}

/// An on/off switch in the theme: on, its track is the theme's focus color
/// (never the system blue); the size of the system's switch.
@MainActor
final class MacScreenSwitch: NSControl, MacScreenInked {
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            setAccessibilityValue(isOn ? 1 : 0)
            refresh(animated: window != nil)
        }
    }
    var onChange: (Bool) -> Void = { _ in }
    private let track = CALayer()
    private let knob = CALayer()
    private var colors = MacScreenColors()
    private static let size = NSSwitch().intrinsicContentSize

    init(id: String, label: String) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityLabel(label)
        setAccessibilityValue(0)
        setAccessibilityIdentifier(id)
        refresh(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var isEnabled: Bool { didSet { refresh(animated: false) } }
    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ colors: MacScreenColors) {
        self.colors = colors
        refresh(animated: false)
    }

    override func layout() {
        super.layout()
        refresh(animated: false)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            if isEnabled { flip() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        flip()
        return true
    }

    private func flip() {
        isOn.toggle()
        onChange(isOn)
    }

    private func refresh(animated: Bool) {
        guard animated else { return Motion.feedback.transaction(nil) { applyState() } }
        Motion.feedback.transaction(spring: .selection) { applyState() }
    }

    private func applyState() {
        let size = bounds.size == .zero ? Self.size : bounds.size
        track.frame = CGRect(origin: .zero, size: size)
        track.cornerRadius = size.height / 2
        let inset: CGFloat = 2
        // The system switch's knob: a capsule 1.6 times as wide as it is tall (32 × 20 in a 54 × 24 track).
        let knobHeight = size.height - inset * 2
        let knobWidth = min(size.width - inset * 2, (knobHeight * 1.6).rounded())
        knob.frame = CGRect(x: isOn ? size.width - inset - knobWidth : inset, y: inset, width: knobWidth, height: knobHeight)
        knob.cornerRadius = knobHeight / 2
        // Off, the system switch's track is the ink at 10% (light gray on light, a lift on dark) and its knob is
        // a light gray in dark mode; on, the track is the theme's focus color.
        track.backgroundColor = (isOn ? colors.focus : colors.primary.withAlphaComponent(0.1)).cgColor
        track.borderWidth = isOn ? 0 : 0.5
        track.borderColor = colors.separator.cgColor
        knob.backgroundColor = (colors.isDark && !isOn ? NSColor(white: 0.886, alpha: 1) : NSColor.white).cgColor
        alphaValue = isEnabled ? 1 : 0.45
    }
}
