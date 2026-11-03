import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing

/// A stored image or SVG icon (`icon-assets-v1`) draws as its image on every surface that shows
/// icons beside the sidebar's workspace rows (cx-qno.2.2): a screen in the screen bar, a tab's user
/// icon in the tab strip, a space in the space bar and a browser profile in its link menu. Until
/// the asset is read a screen keeps the placeholder symbol and a tab its kind icon.
@MainActor
struct AssetIconSurfacesTests {
    static let icon = "svg:sha256-" + String(repeating: "b", count: 64)
    static let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z" fill="#22d"></path></svg>"##.utf8)

    static func decoded() throws -> CGImage {
        try #require(IconAssetImages.decode(svg, mediaType: "image/svg+xml"))
    }

    @Test func aScreenShowsItsStoredIconInTheScreenBar() throws {
        let image = TabImage(try Self.decoded())
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane], icon: Self.icon)
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)

        let drawn = ScreenBarMapping.shared.snapshot(workspace, untitled: { "Screen \($0)" }, emojiIcon: { _ in .none },
                                                     assetIcon: { $0 == Self.icon ? image : nil })
        #expect(drawn.items.first?.icon == .image(image))
        let loading = ScreenBarMapping.shared.snapshot(workspace, untitled: { "Screen \($0)" }, emojiIcon: { _ in .none })
        #expect(loading.items.first?.icon == .symbol("photo"))
    }

    @Test func aTabsStoredUserIconReplacesItsKindIcon() throws {
        let image = TabImage(try Self.decoded())
        let tab = TabModel(TabSnapshot(surface: 1))
        tab.userIcon = Self.icon
        let drawn = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal", asset: { $0 == Self.icon ? image : nil })
        #expect(drawn.icon == .image(image))
        let loading = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal")
        let plain = TabItemMapping.shared.item(TabModel(TabSnapshot(surface: 2)), fallbackTitle: "Terminal")
        #expect(loading.icon == plain.icon, "keeps its kind icon until the asset is read")
    }

    @Test func aSpaceAndABrowserProfileShowTheirStoredIcons() throws {
        let decoded = try Self.decoded()
        let store = DaemonStore()
        store.profiles = [ProfileModel(ProfileSnapshot(id: ProfileID(rawValue: "p1"), name: "Work", icon: Self.icon))]
        let favicon = SidebarFavicon(decoded)
        let spaces = SidebarMapping.spaces(store, image: { $0 == Self.icon ? favicon : nil })
        #expect(spaces.first?.image == favicon)

        let menuImage = NSImage(cgImage: decoded, size: NSSize(width: 16, height: 16))
        let profile = BrowserProfileRecord(id: "bp1", name: "Work", icon: Self.icon)
        let items = BrowserProfileLinkMenu.profileItems([profile], asset: { $0 == Self.icon ? menuImage : nil }, run: { _ in })
        #expect(items.first?.image === menuImage)
    }

    /// The picker stores an asset for a browser profile; the profile keeps it (the daemon's
    /// `update-browser-profile` takes the same forms), where it was silently refused before.
    @Test func aBrowserProfileTakesAStoredIcon() throws {
        var book = BrowserProfileBook()
        try book.setIcon(BrowserProfileRecord.defaultID, Self.icon)
        #expect(book.record(BrowserProfileRecord.defaultID)?.icon == Self.icon)
        #expect(throws: (any Error).self) { try book.setIcon(BrowserProfileRecord.defaultID, "svg:not-a-digest") }
    }
}
