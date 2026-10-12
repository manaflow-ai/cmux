public import AppKit

/// One row of a themed menu (`NSMenu.themeRows(in:)`): the item's state mark, image, title,
/// subtitle, and key equivalent or submenu chevron, highlighted in the theme's accent with its
/// on-accent ink.
///
/// AppKit still tracks the row: arrow keys and the pointer highlight it (`draw` reads
/// `enclosingMenuItem.isHighlighted`), its title feeds type-select, and its submenu opens from it.
/// Two things AppKit does not do for a view row are done here: a click runs the item (AppKit sends
/// no action on mouse-up), and Return delivered to the row runs it too. Every route funnels through
/// the item's `ThemedMenuDispatch`, which runs once per opening.
public final class ThemedMenuRowView: NSView {
    private let scope: ThemeScope
    private let session: ThemedMenuSession
    /// Held here: an item's target is weak.
    private let dispatch: ThemedMenuDispatch?
    /// Draws the row highlighted (or not) without a tracking menu (tests).
    var highlightOverride: Bool?
    /// A press on the row since the menu opened. Without one, a release runs the row only once the
    /// menu has been open a moment, so the release of the right-click that opened it never does.
    private var pressed = false
    private var shownAt: TimeInterval = 0

    init(item: NSMenuItem, scope: ThemeScope, session: ThemedMenuSession) {
        self.scope = scope
        self.session = session
        if let action = item.action {
            let dispatch = ThemedMenuDispatch(target: item.target, action: action, session: session)
            item.target = dispatch
            item.action = #selector(ThemedMenuDispatch.run(_:))
            self.dispatch = dispatch
        } else {
            dispatch = nil
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width(of: item), height: Self.height(of: item)))
        // The menu widens every row to its widest.
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isHighlighted: Bool { highlightOverride ?? (enclosingMenuItem?.isHighlighted == true) }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let item = enclosingMenuItem else { return }
        let lit = isHighlighted && item.isEnabled
        scope.perform {
            if lit {
                Palette.accentFill.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: Self.inset, dy: 0), xRadius: Self.radius, yRadius: Self.radius).fill()
            }
            let ink: NSColor = lit ? Palette.onAccent : item.isEnabled ? .labelColor : .tertiaryLabelColor
            let quiet: NSColor = lit ? Palette.onAccent : item.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
            drawContent(of: item, ink: ink, quiet: quiet)
        }
    }

    private func drawContent(of item: NSMenuItem, ink: NSColor, quiet: NSColor) {
        let font = Self.font(of: item)
        let title = NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: ink])
        let subtitle = Self.subtitle(of: item).map {
            NSAttributedString(string: $0, attributes: [.font: Self.subtitleFont, .foregroundColor: quiet])
        }
        let titleHeight = title.size().height
        // Centered, or the upper line above a subtitle.
        let titleY = subtitle == nil ? (bounds.height - titleHeight) / 2 : bounds.midY
        if item.state != .off {
            NSAttributedString(string: item.state == .on ? "✓" : "–", attributes: [.font: font, .foregroundColor: ink])
                .draw(at: NSPoint(x: Self.markX, y: titleY))
        }
        var x = Self.titleX
        if let image = item.image {
            let rect = NSRect(x: x, y: titleY + (titleHeight - Self.imageSide) / 2, width: Self.imageSide, height: Self.imageSide)
            Self.draw(image, in: rect, tint: image.isTemplate ? ink : nil)
            x += Self.imageSide + Self.gap
        }
        title.draw(at: NSPoint(x: x, y: titleY))
        if let subtitle { subtitle.draw(at: NSPoint(x: x, y: bounds.midY - subtitle.size().height)) }

        let right = bounds.maxX - Self.trailing
        if item.submenu != nil {
            let mid = titleY + titleHeight / 2
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: right - 4, y: mid + 4))
            chevron.line(to: NSPoint(x: right, y: mid))
            chevron.line(to: NSPoint(x: right - 4, y: mid - 4))
            chevron.lineWidth = 1.5
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            ink.setStroke()
            chevron.stroke()
        } else {
            let shortcut = NSAttributedString(string: Self.shortcutText(of: item), attributes: [.font: font, .foregroundColor: quiet])
            shortcut.draw(at: NSPoint(x: right - shortcut.size().width, y: titleY))
        }
    }

    /// A template image in the row's ink; any other as drawn.
    private static func draw(_ image: NSImage, in rect: NSRect, tint: NSColor?) {
        guard let tint, let context = NSGraphicsContext.current?.cgContext else {
            image.draw(in: rect)
            return
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
    }

    // MARK: Activation

    /// Runs the item, as releasing on a native row would: closes the menu and sends the action
    /// once. Rows with a submenu open it instead (AppKit does that).
    func activate() {
        guard let item = enclosingMenuItem, item.isEnabled, item.submenu == nil, item.action != nil,
              let menu = item.menu else { return }
        var root = menu
        while let parent = root.supermenu { root = parent }
        root.cancelTracking()
        if menu !== root { menu.cancelTracking() }
        menu.performActionForItem(at: menu.index(of: item))
    }

    public override func mouseDown(with event: NSEvent) { pressed = true }
    public override func rightMouseDown(with event: NSEvent) { pressed = true }
    public override func mouseUp(with event: NSEvent) { release(event) }
    public override func rightMouseUp(with event: NSEvent) { release(event) }

    private func release(_ event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let settled = shownAt > 0 && event.timestamp - shownAt > Self.openingGrace
        guard inside, pressed || settled else { return }
        activate()
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isHighlighted, Self.isReturn(event) else { return super.performKeyEquivalent(with: event) }
        activate()
        return true
    }

    public override func keyDown(with event: NSEvent) {
        guard isHighlighted, Self.isReturn(event) else { return super.keyDown(with: event) }
        activate()
    }

    public override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }

    /// Return or keypad Enter, without modifiers.
    private static func isReturn(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        return event.type == .keyDown && (event.keyCode == 36 || event.keyCode == 76) && modifiers.isEmpty
    }

    // MARK: Hover and opening

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .enabledDuringMouseDrag, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { needsDisplay = true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // The menu opened (again): its rows may run once more.
        session.reset()
        pressed = false
        shownAt = ProcessInfo.processInfo.systemUptime
        needsDisplay = true
    }
}

extension ThemedMenuRowView {
    static let rowHeight: CGFloat = 22, subtitleRowHeight: CGFloat = 36
    static let inset: CGFloat = 5, radius: CGFloat = 4
    static let markX: CGFloat = 10, titleX: CGFloat = 22, imageSide: CGFloat = 16, gap: CGFloat = 6
    static let trailing: CGFloat = 12, shortcutGap: CGFloat = 28
    /// How long a release with no press on the row is ignored after the menu opens.
    static let openingGrace: TimeInterval = 0.3
    static var subtitleFont: NSFont { .menuFont(ofSize: NSFont.smallSystemFontSize) }

    static func font(of item: NSMenuItem) -> NSFont { item.menu?.font ?? .menuFont(ofSize: 0) }

    static func subtitle(of item: NSMenuItem) -> String? {
        if #available(macOS 14.4, *), let subtitle = item.subtitle, !subtitle.isEmpty { return subtitle }
        return nil
    }

    static func height(of item: NSMenuItem) -> CGFloat { subtitle(of: item) == nil ? rowHeight : subtitleRowHeight }

    static func width(of item: NSMenuItem) -> CGFloat {
        let font = font(of: item)
        func width(_ text: String, _ font: NSFont) -> CGFloat { NSAttributedString(string: text, attributes: [.font: font]).size().width }
        var total = titleX + (item.image == nil ? 0 : imageSide + gap)
        total += max(width(item.title, font), subtitle(of: item).map { width($0, subtitleFont) } ?? 0)
        let shortcut = shortcutText(of: item)
        if item.submenu != nil {
            total += shortcutGap
        } else if !shortcut.isEmpty {
            total += shortcutGap + width(shortcut, font)
        }
        return ceil(total + trailing)
    }

    /// The key equivalent as a menu shows it (⌃⌥⇧⌘ then the key); empty without one.
    static func shortcutText(of item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard let scalar = key.unicodeScalars.first else { return "" }
        let modifiers = item.keyEquivalentModifierMask
        // An uppercase letter implies Shift.
        let shift = modifiers.contains(.shift) || (key != key.lowercased() && key == key.uppercased())
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if shift { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName(scalar.value, key)
    }

    private static func keyName(_ value: UInt32, _ key: String) -> String {
        switch value {
        case 0x0D, 0x03: "↩"
        case 0x09: "⇥"
        case 0x1B: "⎋"
        case 0x08, 0x7F: "⌫"
        case 0x20: "␣"
        case 0xF700: "↑"
        case 0xF701: "↓"
        case 0xF702: "←"
        case 0xF703: "→"
        case 0xF728: "⌦"
        case 0xF729: "↖"
        case 0xF72B: "↘"
        case 0xF72C: "⇞"
        case 0xF72D: "⇟"
        case 0xF704...0xF70F: "F\(value - 0xF704 + 1)"
        default: key.uppercased()
        }
    }
}
