public import AppKit
import ObjectiveC

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
    ///   its mark in its own icon slot, in place of its icon (`MenuMetrics.iconX`; see
    ///   `MenuStateMark.fit` for why its state then reads off and its accessibility value carries it);
    /// - a menu without icons shows the column only when a row is checked or mixed, as a macOS menu
    ///   with no icons does (`MenuMetrics.stateX`, the text at `MenuMetrics.stateIconX`).
    public func fitStateColumn() {
        let rows = items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.view == nil }
        let iconColumn = rows.contains { $0.image != nil }
        if iconColumn { for row in rows { MenuStateMark.fit(row) } }
        showsStateColumn = rows.contains { $0.state != .off }
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
/// mixed row) in the grid's icon box. The mark is set as the menu is themed, and themed menus are
/// built for each open, so a mark is never taken back: a row the caller unchecks in an open menu
/// keeps its mark until the menu is built again. The row itself keeps the icon the mark stands in
/// for (an associated object), so a re-mark (checked, then mixed) keeps that icon and not the first
/// mark; nothing outside the row holds it.
public enum MenuStateMark {
    /// What a marked row drew before its mark, and the mark it draws now.
    final class Replaced {
        let icon: NSImage?
        let mark: NSImage
        let state: NSControl.StateValue
        init(icon: NSImage?, mark: NSImage, state: NSControl.StateValue) {
            self.icon = icon
            self.mark = mark
            self.state = state
        }
    }

    /// The associated-object key: `Replaced`'s class object, one stable address with no storage of its own.
    private static func key() -> UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(Replaced.self as AnyObject).toOpaque()) }

    static func replaced(_ row: NSMenuItem) -> Replaced? {
        guard let kept = objc_getAssociatedObject(row, key()) as? Replaced, kept.mark === row.image else { return nil }
        return kept
    }

    /// Puts a checked or mixed `row`'s mark in its icon slot. AppKit draws a row's state mark in its
    /// own column, and opens that column for any row whose state is not off, whatever
    /// `showsStateColumn` says (measured on the profile menu: the text stayed at 47 with the column
    /// switched off). So the marked row's state goes to off, and the state moves onto the row's own
    /// accessibility value ("checked" or "mixed", `accessibilityStateValue`): VoiceOver reads a
    /// menu row's state from the row, never from its image's description. A caller that sets the
    /// state again re-marks it; a caller that sets a new image owns the slot, and the row stops
    /// saying it is checked.
    static func fit(_ row: NSMenuItem) {
        guard row.state != .off, let mark = image(for: row.state) else {
            // The slot is the caller's again (a new image): the row no longer says it is marked.
            if objc_getAssociatedObject(row, key()) != nil, replaced(row) == nil {
                objc_setAssociatedObject(row, key(), nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                row.setAccessibilityValue(nil)
            }
            return
        }
        let kept = replaced(row)
        let icon = if let kept { kept.icon } else { row.image?.fittedToMenuIconBox() }
        objc_setAssociatedObject(row, key(), Replaced(icon: icon, mark: mark, state: row.state), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        row.setAccessibilityValue(accessibilityStateValue(row.state))
        row.image = mark
        row.state = .off
    }

    /// What VoiceOver says for a slot-marked row's state: "checked" or "mixed", in the app's language.
    public static func accessibilityStateValue(_ state: NSControl.StateValue) -> String {
        state == .mixed
            ? String(localized: "menu.row.state.mixed", defaultValue: "mixed", bundle: .module)
            : String(localized: "menu.row.state.checked", defaultValue: "checked", bundle: .module)
    }

    /// The state a row's slot mark shows (`.on` or `.mixed`), or nil for a row that draws no mark.
    public static func markedState(_ row: NSMenuItem) -> NSControl.StateValue? { replaced(row)?.state }

    /// AppKit's own mark for `state`, a checkmark or a dash, as a template in the grid's icon box.
    static func image(for state: NSControl.StateValue) -> NSImage? {
        let name = state == .mixed ? "minus" : "checkmark"
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold, scale: .small)
        let label = state == .mixed ? "Mixed" : "Checked"
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration) else { return nil }
        symbol.isTemplate = true
        let box = symbol.fittedToMenuIconBox()
        // Always a fresh image in the box, so a row's mark is never another row's.
        return box === symbol ? symbol.copy() as? NSImage : box
    }
}

/// `afterThemedRowRuns`'s step: the run loop keeps its target until it runs.
final class ThemedMenuAfterRun: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    @objc func run() { body() }
}
