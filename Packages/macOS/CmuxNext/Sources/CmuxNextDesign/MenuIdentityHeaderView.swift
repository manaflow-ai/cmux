public import AppKit

/// The name-and-colors header of a right-click menu (Chrome's tab-group menu): a name field over a
/// row of color swatches, on the menu's row grid (MenuMetrics): the field's box on the rows'
/// highlight edges, the first swatch on their icon column. The app's `MenuIdentityHeader` builds it
/// from a menu's rename and color rows.
public final class MenuIdentityHeaderView: NSView, ThemedMenuItemView {
    public let field: MenuNameField?
    public let strip: MenuSwatchStrip?
    static let top: CGFloat = 6, fieldHeight: CGFloat = 24, gap: CGFloat = 4, minimumWidth: CGFloat = 240
    /// The field's box spans the rows' highlight; the strip starts where its first swatch sits on the icon column.
    static var fieldX: CGFloat { MenuMetrics.highlightInset }
    static var stripX: CGFloat { MenuMetrics.iconX - MenuSwatchStrip.ringRoom }

    public init(field: MenuNameField?, strip: MenuSwatchStrip?) {
        self.field = field
        self.strip = strip
        let height = Self.top + (field == nil ? 0 : Self.fieldHeight + Self.gap) + (strip == nil ? 0 : MenuSwatchStrip.height)
        let width = max(Self.minimumWidth, Self.stripX + (strip?.naturalWidth ?? 0) + MenuMetrics.highlightInset)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // The menu widens the header to its widest row.
        autoresizingMask = .width
        if let field { addSubview(field) }
        if let strip { addSubview(strip) }
        layoutParts()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    public func adoptMenuScope(_ scope: ThemeScope) { strip?.adoptMenuScope(scope) }

    public override func layout() {
        super.layout()
        layoutParts()
    }

    private func layoutParts() {
        // Top down in a flipped sense: the field first, the swatches under it.
        var y = bounds.height - Self.top
        if let field {
            y -= Self.fieldHeight
            field.frame = NSRect(x: Self.fieldX, y: y, width: bounds.width - 2 * Self.fieldX, height: Self.fieldHeight)
            y -= Self.gap
        }
        strip?.frame = NSRect(x: Self.stripX, y: y - MenuSwatchStrip.height, width: bounds.width - Self.stripX - Self.fieldX, height: MenuSwatchStrip.height)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let field else { return }
        if window == nil {
            field.menuClosed(by: NSApp.currentEvent)
        } else {
            field.reset()
            // Typing renames at once, as in Chrome; the name starts selected.
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }
}

/// The name field: commits a changed, non-empty name once per opening.
public final class MenuNameField: NSTextField, NSTextFieldDelegate {
    private let original: String
    private let onRename: (String) -> Void
    private var done = false

    public init(name: String, placeholder: String, onRename: @escaping (String) -> Void) {
        original = name
        self.onRename = onRename
        super.init(frame: .zero)
        stringValue = name
        placeholderString = placeholder
        font = .menuFont(ofSize: NSFont.systemFontSize)
        bezelStyle = .roundedBezel
        isBezeled = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        delegate = self
        setAccessibilityLabel(placeholder)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    /// A new opening of the menu: the original name, not yet committed.
    public func reset() {
        done = false
        stringValue = original
    }

    /// Renames once when the name changed and is not blank.
    public func commit() {
        guard !done else { return }
        done = true
        let name = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != original else { return }
        onRename(name)
    }

    /// The menu closed on `event`: a changed name is kept, as Chrome keeps it, unless Escape closed
    /// it. The menu takes Escape before the field editor sees it, so `cancelOperation` never runs.
    public func menuClosed(by event: NSEvent?) {
        if let event, event.type == .keyDown, event.keyCode == Self.escapeKeyCode {
            done = true
            return
        }
        commit()
    }

    private static let escapeKeyCode: UInt16 = 53

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            closeMenu()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            // The arrows leave the field for the menu's rows (the name typed so far is kept); the
            // same press then moves the menu's highlight.
            // Only once the field let go, so the press can't come back here.
            if let window, window.makeFirstResponder(nil), let event = NSApp.currentEvent, event.type == .keyDown { window.sendEvent(event) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape puts the name back and closes the menu, as Escape on any menu does.
            stringValue = original
            done = true
            closeMenu()
            return true
        default:
            return false
        }
    }

    private func closeMenu() {
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
    }
}

/// One row of color swatches; the current one is ringed in the label's ink, the hovered one in the
/// menu scope's accent. VoiceOver offers each color as an action of the row. With a `clear` choice
/// the row starts with a No Color swatch (an empty ring crossed by a slash, Lawrence 2026-10-22:
/// "need to be able to remove all workspace colors").
public final class MenuSwatchStrip: NSView {
    private let choices: [NSMenuItem]
    /// Each choice's color; nil draws the scope's tertiary ink.
    private let colors: [GroupColor?]
    private let current: GroupColor?
    /// The row that removes the color, drawn first as the No Color swatch; nil draws none.
    public let clearChoice: NSMenuItem?
    /// Whether the target has no color now: the No Color swatch is ringed.
    private let clearIsCurrent: Bool
    private var hovered: Int?
    /// The scope of the view whose menu this is (`themeRows(in:)`); nil until a themed menu hands it.
    private var menuScope: ThemeScope?
    static let diameter = MenuMetrics.iconSize, gap: CGFloat = 10, height: CGFloat = 30
    /// Room before the first swatch for the hover and current rings (2.5 pt past the swatch).
    public static let ringRoom: CGFloat = 3

    /// The No Color swatch's name (its VoiceOver action and tooltip).
    public static var noColorTitle: String { String(localized: "menu.swatch.noColor", defaultValue: "No Color", bundle: .module) }

    /// Every swatch in drawing order: the No Color one first when there is one.
    private var swatchCount: Int { choices.count + (clearChoice == nil ? 0 : 1) }

    var naturalWidth: CGFloat { CGFloat(swatchCount) * (Self.diameter + Self.gap) - Self.gap + 2 * Self.ringRoom }

    /// One swatch per choice, drawn in `colors` (same order); `current` is ringed. `clear`, when
    /// given, is the row that removes the color: it draws first as the No Color swatch, ringed when
    /// `clearIsCurrent`.
    public init(title: String, choices: [NSMenuItem], colors: [GroupColor?], current: GroupColor?,
                clear: NSMenuItem? = nil, clearIsCurrent: Bool = false) {
        self.choices = choices
        self.colors = colors
        self.current = clearIsCurrent ? nil : current
        clearChoice = clear
        self.clearIsCurrent = clear != nil && clearIsCurrent
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Self.height))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        let names = (clear == nil ? [] : [Self.noColorTitle]) + choices.map(\.title)
        setAccessibilityCustomActions(names.indices.map { index in
            NSAccessibilityCustomAction(name: names[index]) { [weak self] in
                self?.run(index)
                return self != nil
            }
        })
        showNoColorTip()
    }

    /// The header frames this view by hand: the No Color swatch's tip follows every new size.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        showNoColorTip()
    }

    /// No Color's name as a themed tip over its swatch (a region, so a pointer already inside the
    /// strip when it appears still gets it). Only No Color has a tip, as before.
    private func showNoColorTip() {
        guard clearChoice != nil, let swatch = swatches.first else { return }
        setThemedToolTipRegions([(rect: swatch, text: Self.noColorTitle)])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    public func adoptMenuScope(_ scope: ThemeScope) {
        menuScope = scope
        needsDisplay = true
    }

    /// The hovered swatch's ring: the menu scope's accent.
    @objc public var hoverRingColor: NSColor {
        if let menuScope { return menuScope.perform { Palette.accent } }
        return performWithTheme { Palette.accent }
    }

    /// A swatch whose color can't be read: the scope's tertiary ink, not the system gray.
    @objc public var unknownSwatchColor: NSColor {
        if let menuScope { return menuScope.perform { Palette.textTertiary } }
        return performWithTheme { Palette.textTertiary }
    }

    /// The swatches' rects, from the leading edge past the ring's reach. Read from the bounds each
    /// time: the header sets this view's frame by hand, so no layout pass is promised.
    private var swatches: [NSRect] {
        (0..<swatchCount).map { index in
            NSRect(x: Self.ringRoom + CGFloat(index) * (Self.diameter + Self.gap), y: (bounds.height - Self.diameter) / 2,
                   width: Self.diameter, height: Self.diameter)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let hoverRing = hoverRingColor, unknown = unknownSwatchColor
        let offset = clearChoice == nil ? 0 : 1
        for (index, rect) in swatches.enumerated() {
            if index < offset {
                // No Color: an empty ring crossed by a slash, in the tertiary ink.
                unknown.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
                let slash = NSBezierPath()
                let inset = rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)
                slash.move(to: NSPoint(x: inset.minX, y: inset.minY))
                slash.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
                slash.lineWidth = 1.5
                slash.stroke()
                let ringed = index == hovered ? hoverRing : clearIsCurrent ? NSColor.labelColor : nil
                if let ringed { Self.ring(rect, ringed) }
                continue
            }
            let choice = index - offset
            let color = colors.indices.contains(choice) ? colors[choice] : nil
            (color?.markColor ?? unknown).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let ringed = index == hovered ? hoverRing : color != nil && color == current ? NSColor.labelColor : nil
            if let ringed { Self.ring(rect, ringed) }
        }
    }

    private static func ring(_ rect: NSRect, _ color: NSColor) {
        color.setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    private func swatch(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return swatches.firstIndex { $0.insetBy(dx: -Self.gap / 2, dy: -6).contains(point) }
    }

    public override func mouseMoved(with event: NSEvent) { setHovered(swatch(at: event)) }
    public override func mouseEntered(with event: NSEvent) { setHovered(swatch(at: event)) }
    public override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard let index = swatch(at: event) else { return }
        run(index)
    }

    /// Runs swatch `index` (in drawing order: No Color first when there is one).
    private func run(_ index: Int) {
        let offset = clearChoice == nil ? 0 : 1
        guard let choice = index < offset ? clearChoice : choices.indices.contains(index - offset) ? choices[index - offset] : nil else { return }
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        if let action = choice.action { NSApp.sendAction(action, to: choice.target, from: choice) }
    }
}
