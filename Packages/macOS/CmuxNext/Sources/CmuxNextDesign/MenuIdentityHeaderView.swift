public import AppKit

/// The name-and-colors header of a right-click menu (Chrome's tab-group menu): a name field over a
/// row of color swatches, on the menu's row grid (MenuMetrics). The swatch row spans the column of
/// the separators and the rows' icons, its rings included; the field's box reaches 1 pt past that
/// column on each side, its text 5 pt in (Lucas 2026-11-24, picked in a lab). Each part is one row
/// high, so the header keeps the rows' padding. The app's
/// `MenuIdentityHeader` builds it from a menu's rename and color rows.
public final class MenuIdentityHeaderView: NSView, ThemedMenuItemView {
    public let field: MenuNameField?
    public let strip: MenuSwatchStrip?
    /// `top`: the field's box as far from the menu's top edge as from its sides, 15 pt (the menu's own
    /// 5 pt, then 10). `gap`: the swatches 14 pt under the box.
    static let top: CGFloat = 10, fieldHeight: CGFloat = 24, gap: CGFloat = 9, minimumWidth: CGFloat = 240
    /// The content column's distance from both edges: where the native separators and icons are.
    /// AppKit draws a native row 1 pt in from a row view's frame (the menu's border; measured on
    /// macOS 26: separators 16 pt from the window's edge), so the grid's inset gets that point too.
    static let nativeRowOffset: CGFloat = 1
    static var inset: CGFloat { MenuMetrics.separatorInset + nativeRowOffset }
    /// The field's box: 1 pt past the column on each side, with its own corner radius.
    static var boxInset: CGFloat { inset - 1 }
    static let boxRadius: CGFloat = 6
    /// The field's text as far into the box as a row's highlight sits from the menu's edge.
    static var boxTextInset: CGFloat { MenuMetrics.highlightInset }

    public init(field: MenuNameField?, strip: MenuSwatchStrip?) {
        self.field = field
        self.strip = strip
        let height = Self.top + (field == nil ? 0 : Self.fieldHeight + Self.gap) + (strip == nil ? 0 : MenuSwatchStrip.height)
        let width = max(Self.minimumWidth, 2 * Self.inset + (strip?.naturalWidth ?? 0))
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

    /// A click on the box's padding, outside the text, goes to the field as a click on its text would
    /// (after an arrow moved focus to the rows, the whole box takes it back).
    public override func mouseDown(with event: NSEvent) {
        guard let field, let window, fieldBox.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        FocusRoute(.person, "a click on the menu's name field box").moveKeyboard(in: window, to: field)
    }

    /// The field's box: a faint fill in the label's ink, so it reads in a light or dark menu.
    public override func draw(_ dirtyRect: NSRect) {
        guard field != nil else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: fieldBox, xRadius: Self.boxRadius, yRadius: Self.boxRadius).fill()
    }

    public override func layout() {
        super.layout()
        layoutParts()
    }

    /// The field's box in the header's bounds: a row high, `boxInset` from the sides, under `top`.
    public var fieldBox: NSRect {
        NSRect(x: Self.boxInset, y: bounds.height - Self.top - Self.fieldHeight,
               width: bounds.width - 2 * Self.boxInset, height: Self.fieldHeight)
    }

    private func layoutParts() {
        // Top down in a flipped sense: the field first, the swatches under it.
        var y = bounds.height - Self.top
        if let field {
            let box = fieldBox
            // The text `boxTextInset` into the box; the field one line high, centered in the box.
            let height = ceil(field.intrinsicContentSize.height)
            let x = box.minX + Self.boxTextInset - field.textPadding
            field.frame = NSRect(x: x, y: box.minY + floor((box.height - height) / 2), width: box.maxX - Self.boxTextInset - x, height: height)
            y = box.minY - Self.gap
        }
        strip?.frame = NSRect(x: Self.inset, y: y - MenuSwatchStrip.height, width: bounds.width - 2 * Self.inset, height: MenuSwatchStrip.height)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let field else { return }
        if window == nil {
            field.menuClosed(by: NSApp.currentEvent)
        } else {
            field.reset()
            // Typing goes to the name at once, as in Chrome; the caret starts at its end (`becomeFirstResponder`).
            window?.makeFirstResponder(field)
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
        // The header draws the box (concentric with the menu's corners); the field is the text alone.
        isBezeled = false
        isBordered = false
        drawsBackground = false
        // The field has focus for as long as the menu is open, so a ring says nothing, and it would
        // stick out past the box. The caret and selection show focus.
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        delegate = self
        setAccessibilityLabel(placeholder)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    /// The field editor that takes over while the name is edited paints its own background, which
    /// covered the header's box with a darker band; it draws none here, so the box shows through.
    /// The caret goes to the end of the name, not the whole name selected (Lucas 2026-11-27), so a
    /// keystroke adds to the name; a click still puts the caret where it lands.
    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let editor = currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
        return became
    }

    /// How far in from its frame the cell draws the text (AppKit's padding for a borderless field).
    public var textPadding: CGFloat {
        cell?.drawingRect(forBounds: NSRect(x: 0, y: 0, width: 100, height: 24)).minX ?? 0
    }

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

/// One row of color swatches, spread over the row's width (at least `gap` apart); the current one is
/// ringed in the label's ink, the hovered one in the menu scope's accent. The swatches sit `ringRoom`
/// in from the row's edges, so a ring, even the first swatch's, ends on the column. VoiceOver offers
/// each color as an action of the row. With a `clear` choice the row starts with a No Color swatch
/// (an empty ring crossed by a slash, Lawrence 2026-10-22: "need to be able to remove all workspace colors").
public final class MenuSwatchStrip: NSView {
    private let choices: [NSMenuItem]
    /// Each choice's color; nil draws the scope's tertiary ink.
    let colors: [GroupColor?]
    let current: GroupColor?
    /// The row that removes the color, drawn first as the No Color swatch; nil draws none.
    public let clearChoice: NSMenuItem?
    /// Whether the target has no color now: the No Color swatch is ringed.
    let clearIsCurrent: Bool
    private var hovered: Int?
    /// The scope of the view whose menu this is (`themeRows(in:)`); nil until a themed menu hands it.
    private var menuScope: ThemeScope?
    /// One menu row high: a swatch has an icon's box, so it keeps an icon's room over and under it.
    static let diameter = MenuMetrics.iconSize, gap: CGFloat = 10, height: CGFloat = 24
    /// Room at each end of the row for the hover and current rings (2.5 pt past the swatch, 1.5 pt wide).
    public static let ringRoom: CGFloat = 3

    /// The No Color swatch's name (its VoiceOver action and tooltip).
    public static var noColorTitle: String { String(localized: "menu.swatch.noColor", defaultValue: "No Color", bundle: .localizedModule) }

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

    /// The room between two swatches: the width spread evenly, so the last ring ends where the
    /// separators do; never less than `gap`.
    private var spacing: CGFloat {
        guard swatchCount > 1 else { return Self.gap }
        let free = bounds.width - 2 * Self.ringRoom - CGFloat(swatchCount) * Self.diameter
        return max(Self.gap, free / CGFloat(swatchCount - 1))
    }

    /// The swatches' rects, `ringRoom` in from each edge. Read from the bounds each
    /// time: the header sets this view's frame by hand, so no layout pass is promised.
    private var swatches: [NSRect] {
        let pitch = Self.diameter + spacing
        // On whole pixels: a spread pitch is often a fraction, and a swatch between pixels draws soft.
        let scale = window?.backingScaleFactor ?? 2
        return (0..<swatchCount).map { index in
            let x = ((Self.ringRoom + CGFloat(index) * pitch) * scale).rounded() / scale
            return NSRect(x: x, y: (bounds.height - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
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
        // The nearest swatch, from the drawn (pixel-snapped) rects, so no point between two is dead.
        let point = convert(event.locationInWindow, from: nil), rects = swatches
        guard let nearest = rects.indices.min(by: { abs(rects[$0].midX - point.x) < abs(rects[$1].midX - point.x) }) else { return nil }
        let rect = rects[nearest], reach = (Self.diameter + spacing) / 2 + 1
        return abs(rect.midX - point.x) <= reach && abs(rect.midY - point.y) <= Self.diameter / 2 + 5 ? nearest : nil
    }

    public override func mouseMoved(with event: NSEvent) { setHovered(swatch(at: event)) }
    public override func mouseEntered(with event: NSEvent) { setHovered(swatch(at: event)) }
    public override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    /// The strip takes the press itself. NSView's default hands it up the responder chain to the menu's own
    /// tracking, which then keeps the release, so `mouseUp` never ran and a click on a swatch did nothing (#39953).
    public override func mouseDown(with event: NSEvent) { setHovered(swatch(at: event)) }

    public override func mouseDragged(with event: NSEvent) { setHovered(swatch(at: event)) }

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
