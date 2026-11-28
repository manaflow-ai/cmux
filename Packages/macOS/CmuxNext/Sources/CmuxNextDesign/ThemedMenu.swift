public import AppKit
import CmuxNextCompat

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
    /// AppKit's checkmark column shows only in a menu with a checked or mixed row
    /// (``fitStateColumn()``). Call it last, once the menu is built.
    ///
    /// AppKit adds none of its own rows (Services, Writing Tools, "Ask Siri"): ``withoutSystemItems()``.
    ///
    /// `runsInPlace` is kept for callers: a native row always runs as the menu closes.
    @discardableResult
    public func themeRows(in scope: ThemeScope, runsInPlace: @escaping @MainActor (NSMenuItem) -> Bool = { _ in false }) -> NSMenu {
        withoutSystemItems()
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

    /// AppKit keeps an empty checkmark column at a menu's leading edge unless told otherwise, so a
    /// menu with no checked or mixed row opened with every icon and title pushed right (Leo,
    /// 2026-11-02, on the chat's right-click menu: "why IS THERE SO MUCH ... SPACE AT THE LEFT").
    /// The column stays in a menu that has such a row (`MenuMetrics.stateIconX`).
    public func fitStateColumn() {
        showsStateColumn = items.contains { !$0.isSeparatorItem && !$0.isHidden && $0.state != .off }
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
    /// scaled down to fit when larger, centered up and down, and the left edge of its ink on the
    /// separators' line. Centered, a narrow glyph (the pin) started right of a wide one, and a
    /// symbol's own side margin put every glyph 1 to 2 pt right of the separators and the menu
    /// header (Lucas 2026-11-24: "make sure that everything is aligned and on that red line").
    /// An image already fitted (a `MenuFittedImage`) is returned as it is, so theming a menu twice
    /// changes nothing; one already the box's size still has its ink moved onto the line. A
    /// template stays a template (the menu tints it like the title) and the description
    /// VoiceOver reads is kept.
    public func fittedToMenuIconBox() -> NSImage {
        let side = MenuMetrics.iconSize
        let box = NSSize(width: side, height: side)
        let natural = size
        guard !(self is MenuFittedImage), natural.width > 0, natural.height > 0 else { return self }
        let fit = min(1, side / natural.width, side / natural.height)
        let drawn = NSSize(width: natural.width * fit, height: natural.height * fit)
        let source = self
        // The ink is read the first time the row draws, not as the menu is built: a submenu never
        // opened reads none.
        let lead = MenuIconLead()
        let fitted = MenuFittedImage(size: box, flipped: false) { rect in
            // Read and stored under the lock, measured outside it: a draw never waits on another's render.
            let x: CGFloat
            if let cached = lead.value.withLock({ $0 }) {
                x = cached
            } else {
                x = Self.menuImageColumnLead - (source.inkMinX(drawn: drawn) ?? 0)
                lead.value.withLock { $0 = x }
            }
            source.draw(in: NSRect(x: rect.minX + x, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            return true
        }
        fitted.isTemplate = isTemplate
        fitted.accessibilityDescription = accessibilityDescription
        return fitted
    }

    /// AppKit puts a native row's image 15.75 pt from the menu's edge and its separators at 16 pt
    /// (measured, macOS 26): the ink starts this far into the box to land on the separators' line.
    static let menuImageColumnLead: CGFloat = 0.25

    /// Where this image's ink starts when drawn `drawn` wide: its first column with a visible pixel,
    /// read at 4x on the row's first draw. Nil for an image with no ink.
    private func inkMinX(drawn: NSSize) -> CGFloat? {
        let scale: CGFloat = 4
        let width = Int((drawn.width * scale).rounded(.up)), height = Int((drawn.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.bitmapData else { return nil }
        let stride = bitmap.bytesPerRow
        for x in 0..<width {
            for y in 0..<height where data[y * stride + x * 4 + 3] > 40 { return CGFloat(x) / scale }
        }
        return nil
    }
}

/// A row icon already in the menu grid's box, its ink on the line: theming it again leaves it as it is.
nonisolated final class MenuFittedImage: NSImage {}

/// A fitted row icon's offset in its box, read once on its first draw (the lock makes it Sendable).
private final class MenuIconLead: Sendable {
    let value = Mutex<CGFloat?>(nil)
}

/// `afterThemedRowRuns`'s step: the run loop keeps its target until it runs.
final class ThemedMenuAfterRun: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    @objc func run() { body() }
}
