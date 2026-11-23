import AppKit

/// One line of a ``GlassMenu``: an item, or a separator (`item` nil).
struct GlassMenuRow {
    let item: NSMenuItem?

    /// The visible rows of `menu`: no hidden items, no item with a view of its own (the native header
    /// rows stay in `NSMenu`s), no separator first, last or twice.
    static func rows(of menu: NSMenu) -> [GlassMenuRow] {
        var rows: [GlassMenuRow] = []
        for item in menu.items where !item.isHidden && item.view == nil {
            if item.isSeparatorItem {
                if let last = rows.last, last.item != nil { rows.append(GlassMenuRow(item: nil)) }
            } else {
                rows.append(GlassMenuRow(item: item))
            }
        }
        if let last = rows.last, last.item == nil { rows.removeLast() }
        return rows
    }

    /// The enabled, visible item of `menu` (or of one of its submenus) whose key equivalent `event`
    /// presses, as `NSMenu.performKeyEquivalent(with:)` finds it: the same key, ignoring case, and
    /// the same Command, Option, Control and Shift (an uppercase key equivalent implies Shift).
    static func item(matching event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        guard event.type == .keyDown, let pressed = event.charactersIgnoringModifiers?.lowercased(), !pressed.isEmpty
        else { return nil }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = event.modifierFlags.intersection(relevant)
        for item in menu.items where !item.isHidden && !item.isSeparatorItem {
            if let submenu = item.submenu {
                submenu.update()
                if let found = Self.item(matching: event, in: submenu) { return found }
                continue
            }
            let key = item.keyEquivalent
            guard !key.isEmpty, item.isEnabled, key.lowercased() == pressed else { continue }
            var wanted = item.keyEquivalentModifierMask.intersection(relevant)
            if key != key.lowercased() { wanted.insert(.shift) }
            if wanted == flags { return item }
        }
        return nil
    }

    /// `item`'s shortcut as the menu draws it (⌘, for Settings), or nil without one.
    static func shortcut(_ item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        let shifted = key != key.lowercased()
        if mask.contains(.shift) || shifted { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        let names: [String: String] = ["\r": "↩", "\u{1b}": "⎋", "\t": "⇥", " ": "Space", "\u{8}": "⌫", "\u{7f}": "⌫"]
        return text + (names[key] ?? key.uppercased())
    }
}
