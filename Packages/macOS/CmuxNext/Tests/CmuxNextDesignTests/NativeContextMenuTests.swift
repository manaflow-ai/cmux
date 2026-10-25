import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Every right-click menu is a standard macOS menu (Lawrence 2026-10-23: "make sure our right click
/// stuff context menu is standard macos, in terms of bg, font sizing, etc… we don't want ANYTHING
/// custom besides the icons"). `NSMenu.themeRows(in:)` leaves each row a plain `NSMenuItem`, so AppKit
/// draws its background, font, height, highlight, separators, submenus and shortcuts; the menu only
/// follows the clicked view's light or dark. A row's own view (the sidebar workspace and group
/// menus' name and colors header) stays, and is handed the scope.
@MainActor @Suite(.serialized) struct NativeContextMenuTests {
    private static func darkScope() -> ThemeScope {
        var input = ThemeInput(background: ThemeRGB(hex: 0x1C1B22), foreground: ThemeRGB(hex: 0xE8E4F0))
        input.accentColor = ThemeRGB(hex: 0xE5813A)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Native Menu Dark"), input: input, animated: false)
        return scope
    }

    private static func menu(_ target: NativeMenuTarget, header: NativeMenuHeader? = nil) -> NSMenu {
        _ = NSApplication.shared
        let menu = NSMenu()
        if let header {
            let item = NSMenuItem()
            item.view = header
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let copy = NSMenuItem(title: "Copy", action: #selector(NativeMenuTarget.fire(_:)), keyEquivalent: "c")
        copy.target = target
        copy.image = NSImage.menuSymbol("doc.on.doc")
        menu.addItem(copy)
        menu.addItem(.separator())
        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(NativeMenuTarget.fire(_:)), keyEquivalent: "")
        rename.target = target
        submenu.addItem(rename)
        more.submenu = submenu
        menu.addItem(more)
        return menu
    }

    private static func rows(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem }.flatMap { [$0] + ($0.submenu.map(rows(of:)) ?? []) }
    }

    @Test func everyRowStaysANativeMenuItem() {
        let target = NativeMenuTarget()
        let menu = Self.menu(target)
        menu.themeRows(in: Self.darkScope())
        for item in Self.rows(of: menu) {
            #expect(item.view == nil, "\(item.title) is drawn by a custom view, not AppKit")
            #expect(item.attributedTitle == nil, "\(item.title) has a custom font or color")
        }
        // The item keeps its own action, target, shortcut and icon.
        let copy = menu.items[0]
        #expect(copy.action == #selector(NativeMenuTarget.fire(_:)))
        #expect(copy.target === target)
        #expect(copy.keyEquivalent == "c")
        #expect(copy.image != nil)
        #expect(menu.items[2].submenu?.items.first?.target === target)
    }

    @Test func theMenuKeepsTheSystemFontAndAppearance() {
        let menu = Self.menu(NativeMenuTarget())
        menu.themeRows(in: Self.darkScope())
        #expect(menu.font.pointSize == NSFont.menuFont(ofSize: 0).pointSize, "the menu's font is not the system menu size")
        let names: Set<NSAppearance.Name> = [.aqua, .darkAqua]
        #expect(menu.appearance.map { names.contains($0.name) } ?? true, "the menu draws in a non-system appearance")
        #expect(menu.appearance?.name == .darkAqua, "a dark theme's menu opens in the system dark look")
        #expect(menu.items[2].submenu?.appearance?.name == .darkAqua)
    }

    /// A chosen row runs its own action, sent by AppKit, exactly once.
    @Test func aChosenRowRunsItsOwnAction() {
        let target = NativeMenuTarget()
        let menu = Self.menu(target)
        menu.themeRows(in: Self.darkScope())
        menu.performActionForItem(at: 0)
        #expect(target.count == 1)
    }

    /// The workspace and group menus' header keeps its view and draws in the clicked view's scope.
    @Test func aRowsOwnViewIsKeptAndHandedTheScope() {
        let header = NativeMenuHeader(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let menu = Self.menu(NativeMenuTarget(), header: header)
        let scope = Self.darkScope()
        menu.themeRows(in: scope)
        #expect(menu.items[0].view === header)
        #expect(header.scope === scope)
    }

    /// Icons are the one custom part: system symbols as templates, so AppKit inks them like the
    /// title. A pack name with no SF Symbol of the same name (Chrome's page-menu Cast) draws as
    /// the SF Symbol the icon catalog pairs with it.
    @Test func aPackNameResolvesToItsSystemSymbol() throws {
        let image = try #require(NSImage.menuSymbol("browser.menu.cast"), "Cast has an SF Symbol: airplayvideo")
        #expect(image.isTemplate)
        let system = try #require(NSImage.menuSymbol("airplayvideo"))
        #expect(MenuIconPixels(image) == MenuIconPixels(system))
    }
}

/// An image's alpha drawn into a 32 x 32 px square: two images that draw the same pixels match.
private struct MenuIconPixels: Equatable {
    let alpha: [UInt8]

    @MainActor init(_ image: NSImage) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        alpha = (0..<32).flatMap { y in (0..<32).map { x in UInt8((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255) } }
    }
}

final class NativeMenuTarget: NSObject {
    private(set) var count = 0
    @objc func fire(_ sender: NSMenuItem) { count += 1 }
}

final class NativeMenuHeader: NSView, ThemedMenuItemView {
    private(set) var scope: ThemeScope?
    func adoptMenuScope(_ scope: ThemeScope) { self.scope = scope }
}
