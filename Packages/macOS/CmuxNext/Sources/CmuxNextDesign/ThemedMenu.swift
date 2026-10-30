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
    /// Call it last, once the menu is built.
    ///
    /// `runsInPlace` is kept for callers: a native row always runs as the menu closes.
    @discardableResult
    public func themeRows(in scope: ThemeScope, runsInPlace: @escaping @MainActor (NSMenuItem) -> Bool = { _ in false }) -> NSMenu {
        appearance = scope.appearance
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

/// `afterThemedRowRuns`'s step: the run loop keeps its target until it runs.
final class ThemedMenuAfterRun: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    @objc func run() { body() }
}
