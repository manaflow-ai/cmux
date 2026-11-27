import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Extension rows of a page's context menu carry their extension's icon, as
/// in Chrome (`ContextMenuMatcher::SetExtensionIcon`), and keep Chromium's
/// grouping: one top-level row per extension, a submenu titled with the
/// extension's name when it has more than one item.
@Suite struct BrowserExtensionMenuIconsTests {
    static let onePassword = BrowserExtensionMenuSource(
        id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa", name: "1Password – Password Manager", shortName: "1Password",
        icon1x: "/ext/1p/16.png", icon2x: "/ext/1p/32.png")
    static let bitwarden = BrowserExtensionMenuSource(
        id: "nngceckbapebfimnlniiiahkandclblb", name: "Bitwarden Password Manager", shortName: "Bitwarden",
        icon1x: "/ext/bw/16.png", icon2x: "/ext/bw/32.png")
    static let pocket = BrowserExtensionMenuSource(id: "pocket", name: "Save to Pocket", icon1x: "/ext/p/19.png")
    static let noMenus = BrowserExtensionMenuSource(id: "ublock", name: "uBlock Origin", icon1x: "/ext/u/16.png",
                                                    mayAddMenuItems: false)

    /// Chromium's page menu with 1Password (one parent item with children,
    /// titled by the extension: a submenu), Bitwarden (several top-level
    /// items: grouped under its name) and Pocket (one plain item).
    static let menu: [BrowserContextMenuItem] = [
        BrowserContextMenuItem(id: 33000, title: "Back"),
        BrowserContextMenuItem(id: 0, title: "", kind: .separator),
        BrowserContextMenuItem(id: 49000, title: "1Password", kind: .submenu, children: [
            BrowserContextMenuItem(id: 49001, title: "Autofill"),
            BrowserContextMenuItem(id: 49002, title: "Generate Password"),
        ]),
        BrowserContextMenuItem(id: 49003, title: "Bitwarden Password Manager", kind: .submenu, children: [
            BrowserContextMenuItem(id: 49004, title: "Auto-fill login"),
            BrowserContextMenuItem(id: 0, title: "", kind: .separator),
            BrowserContextMenuItem(id: 49005, title: "Copy username"),
        ]),
        BrowserContextMenuItem(id: 49006, title: "Save Page to Pocket"),
        BrowserContextMenuItem(id: 0, title: "", kind: .separator),
        BrowserContextMenuItem(id: 50162, title: "Inspect"),
    ]

    @Test func everyExtensionRowCarriesItsExtensionsIcon() {
        let icons = BrowserExtensionMenuIcons(sources: [Self.noMenus, Self.pocket, Self.bitwarden, Self.onePassword])
        let rows = icons.annotate(Self.menu)
        #expect(rows[2].extensionID == Self.onePassword.id)
        #expect(rows[2].icon == .image(oneX: "/ext/1p/16.png", twoX: "/ext/1p/32.png"))
        #expect(rows[3].extensionID == Self.bitwarden.id)
        #expect(rows[3].icon == .image(oneX: "/ext/bw/16.png", twoX: "/ext/bw/32.png"))
        #expect(rows[4].extensionID == Self.pocket.id)
        #expect(rows[4].icon == .image(oneX: "/ext/p/19.png", twoX: nil))
        // Not an extension row: no icon.
        #expect(rows[0].icon == nil && rows[6].icon == nil)
    }

    /// Chrome puts the icon only on the extension's top-level row and keeps
    /// Chromium's submenu as it is.
    @Test func groupingStaysAndChildrenHaveNoIcon() {
        let rows = BrowserExtensionMenuIcons(sources: [Self.onePassword, Self.bitwarden, Self.pocket]).annotate(Self.menu)
        #expect(rows.map(\.id) == Self.menu.map(\.id))
        #expect(rows.map(\.kind) == Self.menu.map(\.kind))
        #expect(rows[3].children.map(\.id) == [49004, 0, 49005])
        #expect(rows.flatMap(\.children).allSatisfy { $0.icon == nil && $0.extensionID == nil })
    }

    /// An extension without contextMenus or menus permission adds no row,
    /// so it never takes one; a row no extension explains gets Chrome's
    /// default extension icon.
    @Test func unknownRowsGetTheDefaultExtensionIcon() {
        let menu = [BrowserContextMenuItem(id: 49000, title: "Mystery"), BrowserContextMenuItem(id: 49001, title: "Other")]
        let rows = BrowserExtensionMenuIcons(sources: [Self.noMenus]).annotate(menu)
        #expect(rows.allSatisfy { $0.icon == .defaultExtension && $0.extensionID == nil })
    }

    /// One row and one extension left over belong together, whatever the
    /// row's title.
    @Test func theOnlyLeftoverExtensionOwnsTheOnlyLeftoverRow() {
        let menu = [BrowserContextMenuItem(id: 49000, title: "1Password"), BrowserContextMenuItem(id: 49001, title: "Clip it")]
        let clipper = BrowserExtensionMenuSource(id: "clipper", name: "Web Clipper", icon1x: "/c/16.png")
        let rows = BrowserExtensionMenuIcons(sources: [clipper, Self.onePassword]).annotate(menu)
        #expect(rows.map(\.extensionID) == [Self.onePassword.id, "clipper"])
    }

    @Test func aMenuWithoutExtensionRowsIsUntouched() {
        let menu = [BrowserContextMenuItem(id: 33000, title: "Back"), BrowserContextMenuItem(id: 50162, title: "Inspect")]
        #expect(!BrowserExtensionMenuIcons.hasExtensionRows(menu))
        #expect(BrowserExtensionMenuIcons(sources: [Self.onePassword]).annotate(menu) == menu)
    }

    /// Chrome's choice of manifest icon: the smallest of at least 16 px for
    /// 1x and of at least 32 px for 2x; `__MSG_…__` short names resolve.
    @Test func manifestIconsAndShortName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = """
        {"name": "__MSG_extName__", "short_name": "__MSG_appName__", "default_locale": "en",
         "permissions": ["storage", "contextMenus"],
         "icons": {"128": "images/icon128.png", "19": "images/icon19.png", "48": "/images/icon48.png", "16": "images/icon16.png"}}
        """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try Data(#"{"appName": {"message": "Bitwarden"}}"#.utf8).write(to: folder.appendingPathComponent("_locales/en/messages.json"))
        let source = BrowserExtensionMenuSource(id: "bw", name: "Bitwarden Password Manager", folder: folder)
        #expect(source.shortName == "Bitwarden")
        #expect(source.icon1x == folder.appendingPathComponent("images/icon16.png").path)
        #expect(source.icon2x == folder.appendingPathComponent("images/icon48.png").path)
        #expect(source.mayAddMenuItems)

        let plain = folder.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data(#"{"name": "X", "permissions": ["tabs"]}"#.utf8).write(to: plain.appendingPathComponent("manifest.json"))
        let none = BrowserExtensionMenuSource(id: "x", name: "X", folder: plain)
        #expect(!none.mayAddMenuItems)
        #expect(none.menuIcon == .defaultExtension)
    }

    /// The menu shows the icon: a 16 pt image with the extension's 1x and 2x
    /// files, Chrome's puzzle piece when they do not load. The puzzle is a
    /// menu SF Symbol (`NSImage.menuSymbol`), a template at the menu font's
    /// size like every other right-click icon, not a 16 pt drawing (231a09a0dde).
    @Test @MainActor func theShownRowHasTheIcon() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let oneX = folder.appendingPathComponent("16.png"), twoX = folder.appendingPathComponent("32.png")
        try png(side: 16).write(to: oneX)
        try png(side: 32).write(to: twoX)
        let rows = [
            BrowserContextMenuItem(id: 49000, title: "1Password", icon: .image(oneX: oneX.path, twoX: twoX.path)),
            BrowserContextMenuItem(id: 49001, title: "Broken", icon: .image(oneX: "/nope.png", twoX: nil)),
            BrowserContextMenuItem(id: 50161, title: "Translate to English", icon: .symbol("translate")),
            BrowserContextMenuItem(id: 50162, title: "Inspect"),
        ]
        let request = BrowserContextMenuRequest(items: rows, target: BrowserContextMenuTarget(), location: .zero) { _ in }
        let items = BrowserContextMenuBuilder().items(for: request)
        let image = try #require(items[0].image)
        #expect(image.size == NSSize(width: 16, height: 16))
        #expect(Set(image.representations.map(\.pixelsWide)) == [16, 32])
        let puzzle = try #require(items[1].image)
        #expect(puzzle.isTemplate)
        #expect(puzzle.size == NSImage.menuSymbol(BrowserContextMenuIcon.defaultExtensionSymbol)?.size)
        #expect(try #require(items[2].image).isTemplate)
        #expect(items[3].image == nil)
    }

    private func png(side: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
