import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBookmarks
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Bookmark folders carry an icon (`bookmark-icon-v1`, cx-qno.11.3), the shared icon string: an
/// emoji, an SF Symbol name or a stored image or SVG asset of the home daemon. The daemon's record
/// carries it into the app's tree, the bookmarks bar and the manager page draw it in place of the
/// folder symbol (the folder symbol stands in while a stored asset loads), and Set/Remove Folder
/// Icon are bookmark actions for the right-click menus, the CLI and MCP.
@MainActor @Suite(.serialized)
struct BookmarkFolderIconTests {
    static let asset = "svg:sha256-" + String(repeating: "e", count: 64)

    /// A `bookmarks.*` folder row, with `icon` when given.
    static func folder(_ icon: String?) throws -> BookmarkNode {
        let field = icon.map { #","icon":"\#($0)""# } ?? ""
        let json = #"{"id":"bm_folder","browser_profile_id":"default","parent":"bar","kind":"folder","index":0,"title":"Work","created_ms":1\#(field)}"#
        return try JSONDecoder().decode(BookmarkNode.self, from: Data(json.utf8))
    }

    /// The op's JSON as the daemon gets it.
    static func sent(_ op: BookmarkRoutedClient.Op) throws -> [String: Any] {
        try #require(op.json.foundationObject as? [String: Any])
    }

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    // MARK: The row and the op

    @Test func aFolderRowCarriesItsIcon() throws {
        #expect(try Self.folder("🚀").icon == "🚀")
        #expect(try Self.folder(Self.asset).icon == Self.asset)
        // An older daemon sends no icon: the row still decodes, with none.
        #expect(try Self.folder(nil).icon == nil)
    }

    /// The `update` op sends `icon` only when it changes: a string sets it, null removes it. The
    /// daemon's rule (a folder takes an icon, a URL bookmark refuses one) is cmux-bookmarks-core's.
    @Test func theUpdateOpSendsTheIconOnlyWhenItChanges() throws {
        #expect(try Self.sent(.update(id: "bm_folder", icon: .string("🚀")))["icon"] as? String == "🚀")
        #expect(try Self.sent(.update(id: "bm_folder", icon: .null))["icon"] is NSNull)
        #expect(try Self.sent(.update(id: "bm_folder", title: "Work"))["icon"] == nil)
        #expect(try Self.sent(.update(id: "bm_folder", title: "Work"))["bookmark"] as? String == "bm_folder")
    }

    // MARK: Drawing

    /// A bar folder menu's subfolder row draws the folder's own icon, else the folder symbol.
    @Test func theBarsFolderMenuDrawsAFoldersOwnIconAndTheFolderSymbolWithout() throws {
        let services = Self.services()
        func image(_ icon: String?) throws -> Data? {
            let row = BookmarksBarMenu.Row.folder(try Self.folder(icon), [])
            let menu = BookmarksBarMenu(host: services, profile: "default", tabKey: "bookmark-folder-icon-test", rows: [row], title: "Work")
            menu.menuNeedsUpdate(menu.menu)
            return menu.menu.items.first?.image?.tiffRepresentation
        }
        let plain = try #require(try image(nil))
        for icon in ["🚀", "star.fill"] {
            let drawn = try #require(try image(icon))
            #expect(drawn != plain, "a folder with icon \(icon) still draws the folder symbol in the bar's menu")
        }
        // A stored asset not read yet (no home daemon here): the folder symbol stands in.
        #expect(try image(Self.asset) == plain)
    }

    /// The manager page's rows get these images (`cmux.bookmarkPage.icons`).
    @Test func theManagerDrawsAFoldersEmojiOrStoredIcon() throws {
        let bookmarks = Self.services().bookmarks
        #expect(bookmarks.folderIconImage(of: try Self.folder(nil), side: 32) == nil, "a folder without an icon draws the folder symbol")
        #expect(bookmarks.folderIconImage(of: try Self.folder("🚀"), side: 32) != nil, "an emoji folder icon draws in its own colors")
        #expect(bookmarks.folderIconImage(of: try Self.folder(Self.asset), side: 32) == nil, "the folder symbol stands in while the asset loads")
    }

    /// The React page asks the host for the icons of the rows on screen: an emoji folder gets its
    /// image, a folder without an icon and an unknown id get none, and the state names the profile.
    /// The app's page host names the profile and hands the manager page a folder's own icon.
    @Test func theManagerPageGetsAFoldersIconFromItsHost() async throws {
        let services = Self.services()
        let host = BookmarkPageHostProvider(host: services, tabKey: "bookmark-page-host-test")
        let context = PageCallContext(page: PageDescriptor.bookmarks.id)
        let state = try await host.call("cmux.bookmarkPage.state", params: .object([:]), context: context)
        #expect(state["browser_profile_id"]?.stringValue == "default")
        let emoji = try #require(services.bookmarkFolderIcon(try Self.folder("🚀"), side: 32))
        #expect(!emoji.isTemplate, "an emoji draws in its own colors, not as a mask")
        #expect(services.bookmarkFolderIcon(try Self.folder(nil), side: 32) == nil)
    }

    // MARK: Actions

    @Test func setAndRemoveFolderIconAreBookmarkActions() throws {
        for (id, cli) in [("bookmark.setIcon", "bookmark set-icon"), ("bookmark.clearIcon", "bookmark clear-icon")] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id }, "\(id) is in the catalog")
            #expect(descriptor.targets.contains(.bookmark))
            #expect(descriptor.cliName == cli)
        }
        let set = try #require(ActionCatalog.all.first { $0.id.rawValue == "bookmark.setIcon" })
        #expect(set.arguments.contains { $0.name == "icon" }, "the CLI and MCP name the icon")
    }

    /// The palette (which has no folder to act on) leaves both actions out. A bar's right-click acts
    /// on the row the bar drew at once, with no daemon read; a name from the CLI or MCP (a folder's
    /// title ahead of a bookmark matching the same words) resolves on the daemon's tree
    /// (`bookmarks.resolve`, cmux-bookmarks-ops `lookup`), never on a copy in the app.
    @Test func aBarMenuRowActsOnTheFolderTheBarDrew() throws {
        for id in ["bookmark.setIcon", "bookmark.clearIcon"] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id })
            #expect(!descriptor.surfaces.contains(.palette), "\(id) has no folder to act on from the palette")
        }
        let services = Self.services()
        services.bookmarks.menuTarget = .init(id: "bm_folder", profile: "work", isFolder: true, icon: "🚀")
        let resolver = BookmarkResolver(services: services)
        var acted: [String] = []
        let menu = ActionInvocation(target: ActionTargetRef(kind: .bookmark, id: "bm_folder"))
        BookmarkIconHandlers.withFolder(menu, resolver) { folder, profile in
            acted.append("\(folder.id) \(folder.icon ?? "-") \(profile)")
        }
        #expect(acted == ["bm_folder 🚀 work"], "the same turn, on the bar's row and profile")
        #expect(resolver.profile(menu) == "work")

        // A URL bookmark's menu has no folder rows; its invocation goes to the daemon instead.
        services.bookmarks.menuTarget = .init(id: "bm_url", profile: "work", isFolder: false, icon: nil)
        BookmarkIconHandlers.withFolder(ActionInvocation(target: ActionTargetRef(kind: .bookmark, id: "bm_url")), resolver) { _, _ in
            acted.append("url")
        }
        #expect(acted.count == 1)
    }

    /// Only an implicit name is exact: a bar's row (its id) and the focused page's URL resolve on the
    /// daemon as an id or a link to the same page (`exact`, cmux-bookmarks-ops `find_exact`), so
    /// Delete Bookmark on a page with no bookmark of its own never deletes another page's by a text
    /// match. Text the person typed still matches the way the omnibar does.
    @Test func onlyAnImplicitNameResolvesExactly() {
        let resolver = BookmarkResolver(services: Self.services())
        let typed = ActionInvocation(arguments: ["bookmark": .string(" docs ")])
        #expect(resolver.name(typed) == BookmarkResolver.Name(text: "docs", exact: false))
        let row = ActionInvocation(target: ActionTargetRef(kind: .bookmark, id: "bm_folder"))
        #expect(resolver.name(row) == BookmarkResolver.Name(text: "bm_folder", exact: true))
        #expect(resolver.name(ActionInvocation()) == nil, "no argument and no focused page names nothing")

        let exact = BookmarkRoutedClient.resolveParams(profile: "default", bookmark: "https://example.com/", exact: true,
                                                       foldersFirst: false, folder: nil, fallback: nil, url: nil)
        #expect(exact["exact"] == .bool(true))
        #expect(exact["bookmark"] == .string("https://example.com/"))
        let loose = BookmarkRoutedClient.resolveParams(profile: "default", bookmark: "docs", exact: false,
                                                       foldersFirst: false, folder: nil, fallback: nil, url: nil)
        #expect(loose["exact"] == nil)
    }

    /// Folder icons live in the home daemon's bookmarks: without `bookmark-icon-v1` there (an
    /// older daemon, or none yet) the actions say why instead of doing nothing.
    @Test func folderIconActionsWaitForAHomeDaemonThatServesThem() {
        let services = Self.services()
        AppActions.bind(services)
        for id: ActionID in ["bookmark.setIcon", "bookmark.clearIcon"] {
            #expect(services.registry.unavailableReason(for: id) != nil, "\(id) runs without bookmark-icon-v1")
        }
    }
}
