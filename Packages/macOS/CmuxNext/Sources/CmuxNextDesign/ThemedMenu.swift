public import AppKit

extension NSMenu {
    /// Opens this menu, and its submenus, in the light or dark system look of `scope`, the view
    /// that was right-clicked. Every row stays a plain `NSMenuItem` that AppKit draws: the system
    /// background, menu font, row height, highlight, separators, submenus and key equivalents
    /// (Lawrence 2026-10-23: "make sure our right click stuff context menu is standard macos ...
    /// we don't want ANYTHING custom besides the icons"). Icons are the items' images
    /// (`NSImage.menuSymbol`). A row that has its own view (the sidebar workspace and group menus'
    /// name and colors header) keeps it; a `ThemedMenuItemView` is handed the scope to draw in.
    /// A native row's image goes in the menu grid's icon box (`MenuMetrics.iconSize`, its shape
    /// kept), so AppKit's one image column is the grid's in every menu and every row's text starts
    /// on `MenuMetrics.textX(iconColumn:)`: an avatar or a wide symbol no longer moves it.
    /// A menu has one leading column: its icons', with a checked row's mark in that row's icon
    /// slot, or, in a menu with no icons, AppKit's checkmark column when a row is checked or mixed
    /// (``fitStateColumn()``). Call it last, once the menu is built.
    ///
    /// `runsInPlace` is kept for callers: a native row always runs as the menu closes.
    @discardableResult
    public func themeRows(in scope: ThemeScope, runsInPlace: @escaping @MainActor (NSMenuItem) -> Bool = { _ in false }) -> NSMenu {
        appearance = scope.appearance
        fitStateColumn()
        for item in items where !item.isSeparatorItem {
            (item.view as? any ThemedMenuItemView)?.adoptMenuScope(scope)
            if item.view == nil, let image = item.image { item.image = image.fittedToMenuIconBox() }
            if let submenu = item.submenu { submenu.themeRows(in: scope) }
        }
        return self
    }

    /// Rows added since the menu was themed (a search's results while it is open) are native
    /// rows already; their icons go in the grid's box as the first rows' did, so filtering never
    /// changes an icon's size. Rows already fitted are left as they are.
    public func themeAddedRows() {
        fitRowIcons()
        fitStateColumn()
    }

    /// One leading column per menu. AppKit keeps an empty checkmark column at a menu's leading edge
    /// unless told otherwise, so a menu with no checked or mixed row opened with every icon and title
    /// pushed right (Leo, 2026-11-02, on the chat's right-click menu: "why IS THERE SO MUCH ... SPACE
    /// AT THE LEFT"). A menu whose rows carry icons and has a checked row stacked the checkmark column
    /// and the icon column, a double gutter left of every row (Leo, 2026-11-10, on the profile
    /// menu's team rows: "this is too big at the left i think", "at the very least it's awkward
    /// looking"). So:
    /// - a menu with an icon column never shows the checkmark column: a checked or mixed row draws
    ///   its mark in its own icon slot, in place of its icon (`MenuMetrics.iconX`), and gets its icon
    ///   back when it is no longer checked;
    /// - a menu without icons shows the column only when a row is checked or mixed, as a macOS menu
    ///   with no icons does (`MenuMetrics.stateX`, the text at `MenuMetrics.stateIconX`).
    /// The row's `state` is left as it is, so VoiceOver still reads it as checked.
    public func fitStateColumn() {
        let rows = items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.view == nil }
        let marked = rows.contains { $0.state != .off }
        let iconColumn = rows.contains { $0.image != nil }
        showsStateColumn = marked && !iconColumn
        guard iconColumn else { return }
        for row in rows { MenuStateMarkImage.fit(row) }
    }

    /// Every native row's image, its submenus' too, in the grid's icon box.
    private func fitRowIcons() {
        for item in items where !item.isSeparatorItem && item.view == nil {
            if let image = item.image { item.image = image.fittedToMenuIconBox() }
            item.submenu?.fitRowIcons()
        }
    }

    /// Runs `body` once the row chosen in this menu has run. AppKit runs a chosen row before
    /// `popUp` returns, so code that follows `popUp` and settles the menu's outcome (a page menu
    /// that ends a dismissed request) runs it on the next turn of the run loop.
    public func afterThemedRowRuns(_ body: @escaping @MainActor () -> Void) {
        let step = ThemedMenuAfterRun { [self] in
            _ = self
            body()
        }
        RunLoop.main.perform(#selector(ThemedMenuAfterRun.run), target: step, argument: nil, order: 0, modes: [.default])
    }
}

extension NSImage {
    /// This image in the menu grid's square icon box (`MenuMetrics.iconSize`), its shape kept:
    /// scaled down to fit when larger, centered when smaller. An image already the box's size is
    /// returned as it is, so theming a menu twice changes nothing. A template stays a template
    /// (the menu tints it like the title) and the description VoiceOver reads is kept.
    public func fittedToMenuIconBox() -> NSImage {
        let side = MenuMetrics.iconSize
        let box = NSSize(width: side, height: side)
        let natural = size
        guard natural != box, natural.width > 0, natural.height > 0 else { return self }
        let source = self
        let fitted = NSImage(size: box, flipped: false) { rect in
            let fit = min(1, rect.width / natural.width, rect.height / natural.height)
            let drawn = NSSize(width: natural.width * fit, height: natural.height * fit)
            source.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                   width: drawn.width, height: drawn.height))
            return true
        }
        fitted.isTemplate = isTemplate
        fitted.accessibilityDescription = accessibilityDescription
        return fitted
    }
}

/// A checked row's mark in its icon slot (`NSMenu.fitStateColumn()`): the checkmark (a dash for a
/// mixed row) in the grid's icon box. The mark carries the icon it stands in for, so the row gets
/// that icon back when it is no longer checked; nothing outside the row keeps it.
final class MenuStateMarkImage: NSImage, @unchecked Sendable {
    /// The row's own icon, in the grid's box (nil for a row that had none).
    let icon: NSImage?
    let state: NSControl.StateValue

    init?(state: NSControl.StateValue, replacing icon: NSImage?) {
        let name = state == .mixed ? "minus" : "checkmark"
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold, scale: .small)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        self.icon = icon?.fittedToMenuIconBox()
        self.state = state
        let side = MenuMetrics.iconSize
        super.init(size: NSSize(width: side, height: side))
        let natural = symbol.size
        addRepresentation(NSCustomImageRep(size: size, flipped: false) { rect in
            let fit = min(1, rect.width / max(natural.width, 1), rect.height / max(natural.height, 1))
            let drawn = NSSize(width: natural.width * fit, height: natural.height * fit)
            symbol.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            return true
        })
        isTemplate = true
        accessibilityDescription = state == .mixed ? "Mixed" : "Checked"
    }

    required init?(coder: NSCoder) { nil }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { nil }

    /// Puts `row`'s mark in its icon slot when it is checked or mixed, and its icon back when not.
    /// A caller that set a new image since the mark went in owns the slot again.
    @MainActor static func fit(_ row: NSMenuItem) {
        let current = row.image as? MenuStateMarkImage
        guard row.state != .off else {
            if let current { row.image = current.icon }
            return
        }
        guard current?.state != row.state else { return }
        let icon = if let current { current.icon } else { row.image }
        if let mark = MenuStateMarkImage(state: row.state, replacing: icon) { row.image = mark }
    }
}

/// `afterThemedRowRuns`'s step: the run loop keeps its target until it runs.
final class ThemedMenuAfterRun: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    @objc func run() { body() }
}
