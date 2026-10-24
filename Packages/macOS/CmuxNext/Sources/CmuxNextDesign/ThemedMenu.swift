public import AppKit

extension NSMenu {
    /// Opens this menu, and its submenus, in the light or dark system look of `scope`, the view
    /// that was right-clicked. Every row stays a plain `NSMenuItem` that AppKit draws: the system
    /// background, menu font, row height, highlight, separators, submenus and key equivalents
    /// (Lawrence 2026-10-23: "make sure our right click stuff context menu is standard macos ...
    /// we don't want ANYTHING custom besides the icons"). Icons are the items' images
    /// (`NSImage.menuSymbol`). A row that has its own view (the sidebar workspace and group menus'
    /// name and colors header) keeps it; a `ThemedMenuItemView` is handed the scope to draw in.
    /// Call it last, once the menu is built.
    ///
    /// `runsInPlace` is kept for callers: a native row always runs as the menu closes.
    @discardableResult
    public func themeRows(in scope: ThemeScope, runsInPlace: @escaping @MainActor (NSMenuItem) -> Bool = { _ in false }) -> NSMenu {
        appearance = scope.appearance
        for item in items where !item.isSeparatorItem {
            (item.view as? any ThemedMenuItemView)?.adoptMenuScope(scope)
            if let submenu = item.submenu { submenu.themeRows(in: scope) }
        }
        return self
    }

    /// Rows added since the menu was themed (a search's results while it is open) are native
    /// rows already; nothing to do.
    public func themeAddedRows() {}

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

/// `afterThemedRowRuns`'s step: the run loop keeps its target until it runs.
final class ThemedMenuAfterRun: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    @objc func run() { body() }
}
