import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The top of the workspace and group right-click menus, as in Chrome's tab-group menu (Leo
/// 2026-10-20: "why are the right-click things not like Chrome?"): the name in a field you can
/// edit in place, then the colors as one row of swatches with the current one ringed. It takes the
/// place of the menu's Rename… row and its color submenu; a separator divides it from the rest.
///
/// The field renames when Return is pressed or the menu closes with a changed name (Chrome keeps
/// what you typed too), through the rename action with a `name` argument. A swatch runs its color
/// choice as the color row did.
@MainActor
enum MenuIdentityHeader {
    /// Puts the header at the top of `menu`. `rename` is the menu's rename action; its row leaves the
    /// menu, and without it (a multi-row selection) the header shows only the swatches. The color
    /// choices are the rows of the submenu whose rows each set a group color; `current` rings one
    /// when the rows carry no state (the group menu). A menu with neither is left as it is.
    static func install(in menu: NSMenu, registry: ActionRegistry, target: ActionTargetRef, name: String?, rename: ActionID,
                        current: GroupColor? = nil) {
        let renameIndex = name == nil ? nil : menu.items.firstIndex { ActionRegistry.menuRun(of: $0)?.id == rename }
        let colorIndex = menu.items.firstIndex { item in
            (item.submenu?.items.filter { color(of: $0) != nil }.count ?? 0) >= 2
        }
        guard renameIndex != nil || colorIndex != nil else { return }
        let choices = colorIndex.map { menu.items[$0].submenu?.items.filter { color(of: $0) != nil } ?? [] } ?? []
        let colorTitle = colorIndex.map { menu.items[$0].title }
        for index in [renameIndex, colorIndex].compactMap({ $0 }).sorted(by: >) { menu.removeItem(at: index) }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }

        let field = renameIndex.map { _ in
            NameField(name: name ?? "", placeholder: placeholder(for: rename, registry: registry)) { newName in
                // With a name the rename only sends it; it opens no field of its own.
                registry.perform(rename, invocation: ActionInvocation(target: target, arguments: ["name": .string(newName)]))
            }
        }
        let ringed = current ?? choices.first { $0.state == .on }.flatMap(color(of:))
        let strip = choices.isEmpty ? nil : SwatchStrip(title: colorTitle ?? "", choices: choices, current: ringed)
        let header = NSMenuItem()
        header.view = MenuIdentityHeaderView(field: field, strip: strip)
        if let colorTitle { header.setAccessibilityLabel(colorTitle) }
        menu.insertItem(header, at: 0)
        if menu.items.count > 1 { menu.insertItem(.separator(), at: 1) }
    }

    /// The group color a menu row sets: a choices row's `color` argument (Set Workspace Color) or a
    /// group's per-color action (`workspaceGroup.color.<color>`).
    static func color(of item: NSMenuItem) -> GroupColor? {
        guard let run = ActionRegistry.menuRun(of: item) else { return nil }
        if let raw = run.arguments["color"]?.stringValue { return GroupColor(rawValue: raw) }
        let prefix = "workspaceGroup.color."
        guard run.id.rawValue.hasPrefix(prefix) else { return nil }
        return GroupColor(rawValue: String(run.id.rawValue.dropFirst(prefix.count)))
    }

    /// The field's placeholder: the rename action's `name` argument ("Name"), else its title.
    private static func placeholder(for rename: ActionID, registry: ActionRegistry) -> String {
        registry.descriptor(for: rename)?.arguments.first { $0.name == "name" }?.title ?? registry.title(for: rename) ?? ""
    }
}

/// The header's view: the name field over the swatches, inset as the menu's rows are.
final class MenuIdentityHeaderView: NSView, ThemedMenuItemView {
    let field: NameField?
    let strip: SwatchStrip?
    static let inset: CGFloat = 12, top: CGFloat = 6, fieldHeight: CGFloat = 24, gap: CGFloat = 4, minimumWidth: CGFloat = 240

    init(field: NameField?, strip: SwatchStrip?) {
        self.field = field
        self.strip = strip
        let height = Self.top + (field == nil ? 0 : Self.fieldHeight + Self.gap) + (strip == nil ? 0 : SwatchStrip.height)
        let width = max(Self.minimumWidth, (strip?.naturalWidth ?? 0) + 2 * Self.inset)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // The menu widens the header to its widest row.
        autoresizingMask = .width
        if let field { addSubview(field) }
        if let strip { addSubview(strip) }
        layoutParts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func adoptMenuScope(_ scope: ThemeScope) { strip?.adoptMenuScope(scope) }

    override func layout() {
        super.layout()
        layoutParts()
    }

    private func layoutParts() {
        // Top down in a flipped sense: the field first, the swatches under it.
        var y = bounds.height - Self.top
        if let field {
            y -= Self.fieldHeight
            field.frame = NSRect(x: Self.inset, y: y, width: bounds.width - 2 * Self.inset, height: Self.fieldHeight)
            y -= Self.gap
        }
        strip?.frame = NSRect(x: Self.inset, y: y - SwatchStrip.height, width: bounds.width - 2 * Self.inset, height: SwatchStrip.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let field else { return }
        if window == nil {
            // The menu closed: a changed name is kept, as Chrome keeps it.
            field.commit()
        } else {
            field.reset()
            // Typing renames at once, as in Chrome; the name starts selected.
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }
}

/// The name field: commits a changed, non-empty name once per opening.
final class NameField: NSTextField, NSTextFieldDelegate {
    private let original: String
    private let onRename: (String) -> Void
    private var done = false

    init(name: String, placeholder: String, onRename: @escaping (String) -> Void) {
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
    required init?(coder: NSCoder) { fatalError() }

    /// A new opening of the menu: the original name, not yet committed.
    func reset() {
        done = false
        stringValue = original
    }

    /// Renames once when the name changed and is not blank.
    func commit() {
        guard !done else { return }
        done = true
        let name = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != original else { return }
        onRename(name)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
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
/// menu scope's accent. VoiceOver offers each color as an action of the row.
final class SwatchStrip: NSView {
    private let choices: [NSMenuItem]
    private let current: GroupColor?
    private var swatches: [NSRect] = []
    private var hovered: Int?
    /// The scope of the view whose menu this is (`themeRows(in:)`); nil until a themed menu hands it.
    private var menuScope: ThemeScope?
    static let diameter: CGFloat = 16, gap: CGFloat = 10, height: CGFloat = 30

    var naturalWidth: CGFloat { CGFloat(choices.count) * (Self.diameter + Self.gap) - Self.gap + 6 }

    init(title: String, choices: [NSMenuItem], current: GroupColor?) {
        self.choices = choices
        self.current = current
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Self.height))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        setAccessibilityCustomActions(choices.indices.map { index in
            NSAccessibilityCustomAction(name: choices[index].title) { [weak self] in
                self?.run(index)
                return self != nil
            }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func adoptMenuScope(_ scope: ThemeScope) {
        menuScope = scope
        needsDisplay = true
    }

    /// The hovered swatch's ring: the menu scope's accent.
    @objc var hoverRingColor: NSColor {
        if let menuScope { return menuScope.perform { Palette.accent } }
        return performWithTheme { Palette.accent }
    }

    /// A swatch whose color can't be read: the scope's tertiary ink, not the system gray.
    @objc var unknownSwatchColor: NSColor {
        if let menuScope { return menuScope.perform { Palette.textTertiary } }
        return performWithTheme { Palette.textTertiary }
    }

    override func layout() {
        super.layout()
        // From the leading edge, past the ring's reach.
        var x: CGFloat = 3
        swatches = choices.map { _ in
            defer { x += Self.diameter + Self.gap }
            return NSRect(x: x, y: (bounds.height - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let hoverRing = hoverRingColor, unknown = unknownSwatchColor
        for (index, rect) in swatches.enumerated() {
            let color = MenuIdentityHeader.color(of: choices[index])
            (color?.markColor ?? unknown).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let ringed = index == hovered ? hoverRing : color != nil && color == current ? NSColor.labelColor : nil
            if let ringed {
                ringed.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }

    private func swatch(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return swatches.firstIndex { $0.insetBy(dx: -Self.gap / 2, dy: -6).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { setHovered(swatch(at: event)) }
    override func mouseEntered(with event: NSEvent) { setHovered(swatch(at: event)) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = swatch(at: event) else { return }
        run(index)
    }

    private func run(_ index: Int) {
        let choice = choices[index]
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        if let action = choice.action { NSApp.sendAction(action, to: choice.target, from: choice) }
    }
}
