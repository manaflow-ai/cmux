import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBookmarks
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

    /// A `list-bookmarks` folder row, with `icon` when given.
    static func record(icon: String?) throws -> BookmarkRecord {
        let field = icon.map { #","icon":"\#($0)""# } ?? ""
        let json = #"{"id":"bm_folder","browser_profile_id":"default","parent":"bar","kind":"folder","index":0,"title":"Work","created_ms":1\#(field)}"#
        return try JSONDecoder().decode(BookmarkRecord.self, from: Data(json.utf8))
    }

    /// The folder as the app's tree holds it, mapped from the daemon's record.
    static func folder(_ icon: String?) throws -> BookmarkNode {
        BookmarkService.node(from: try record(icon: icon))
    }

    /// The node as the bookmark file stores it.
    static func stored(_ node: BookmarkNode) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
    }

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    // MARK: The record

    @Test func aFolderRecordCarriesItsIconIntoTheAppsTree() throws {
        #expect(try Self.stored(Self.folder("🚀"))["icon"] as? String == "🚀")
        #expect(try Self.stored(Self.folder(Self.asset))["icon"] as? String == Self.asset)
        // An older daemon sends no icon: the record still decodes, with none.
        #expect(try Self.stored(Self.folder(nil))["icon"] == nil)
    }

    // MARK: The request

    /// `update-bookmark` sends `icon` only when it changes: a string sets it, null removes it.
    @Test func updateBookmarkSendsTheIconOnlyWhenItChanges() throws {
        func sent(_ icon: FieldUpdate<String>) throws -> [String: Any] {
            let data = try JSONEncoder().encode(UpdateBookmarkRequest(bookmark: "bm_folder", icon: icon, mutation: nil))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try sent(.set("🚀"))["icon"] as? String == "🚀")
        #expect(try sent(.clear)["icon"] is NSNull)
        #expect(try sent(.unchanged)["icon"] == nil)
    }

    /// The edit the app applies and sends follows the daemon's rule: a folder takes an icon, a
    /// URL bookmark refuses one (a removal too).
    @Test func onlyAFolderTakesAnIcon() throws {
        var tree = BookmarkTree()
        try tree.apply(.create(.folder("Work", in: BookmarkRoot.bar.rawValue, id: "bm_folder"), index: nil))
        let url = try #require(URL(string: "https://example.com"))
        try tree.apply(.create(.bookmark("Example", url: url, in: "bm_folder", id: "bm_url"), index: nil))
        try tree.apply(.update(id: "bm_folder", icon: .set("🚀")))
        #expect(tree.node("bm_folder")?.icon == "🚀")
        #expect(throws: BookmarkError.self) { try tree.apply(.update(id: "bm_url", icon: .set("🚀"))) }
        #expect(throws: BookmarkError.self) { try tree.apply(.update(id: "bm_url", icon: .clear)) }
        try tree.apply(.update(id: "bm_folder", icon: .clear))
        #expect(tree.node("bm_folder")?.icon == nil)
    }

    // MARK: Drawing

    @Test func theBarDrawsAFoldersOwnIconAndTheFolderSymbolWithout() throws {
        let services = Self.services()
        let bar = BookmarkBarSourceAdapter(service: services.bookmarks, tabKey: "bookmark-folder-icon-test")
        let plain = try #require(bar.favicon(for: try Self.folder(nil))?.tiffRepresentation)
        for icon in ["🚀", "star.fill"] {
            let drawn = try #require(bar.favicon(for: try Self.folder(icon))?.tiffRepresentation)
            #expect(drawn != plain, "a folder with icon \(icon) still draws the folder symbol on the bar")
        }
        // A stored asset not read yet (no home daemon here): the folder symbol stands in.
        #expect(bar.favicon(for: try Self.folder(Self.asset))?.tiffRepresentation == plain)
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
    @Test func theManagerPageGetsAFoldersIconFromItsHost() async throws {
        let services = Self.services()
        var tree = BookmarkTree()
        try tree.apply(.create(.folder("Work", in: BookmarkRoot.bar.rawValue, id: "bm_emoji"), index: nil))
        try tree.apply(.create(.folder("Plain", in: BookmarkRoot.bar.rawValue, id: "bm_plain"), index: nil))
        try tree.apply(.update(id: "bm_emoji", icon: .set("🚀")))
        services.bookmarks.trees["default"] = tree
        let host = BookmarkPageHostProvider(host: services, tabKey: "bookmark-page-host-test")
        let context = PageCallContext(page: PageDescriptor.bookmarks.id)
        let state = try await host.call("cmux.bookmarkPage.state", params: .object([:]), context: context)
        #expect(state["browser_profile_id"]?.stringValue == "default")
        let ids: [JSONValue] = [.string("bm_emoji"), .string("bm_plain"), .string("bm_gone")]
        let reply = try await host.call("cmux.bookmarkPage.icons", params: .object(["ids": .array(ids)]), context: context)
        let icons = reply["icons"]?.objectValue ?? [:]
        #expect(icons["bm_emoji"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        #expect(icons["bm_plain"] == nil && icons["bm_gone"] == nil)
        #expect(reply["masks"]?.arrayValue == [], "an emoji draws in its own colors, not as a mask")
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

    /// The CLI names a folder by its title even when a bookmark inside it matches the same words
    /// first, and the palette (which has no folder to act on) leaves both actions out.
    @Test func theCLINamesAFolderByTitleAheadOfAMatchingBookmark() throws {
        for id in ["bookmark.setIcon", "bookmark.clearIcon"] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id })
            #expect(!descriptor.surfaces.contains(.palette), "\(id) has no folder to act on from the palette")
        }
        let services = Self.services()
        var tree = BookmarkTree()
        try tree.apply(.create(.folder("Work", in: BookmarkRoot.bar.rawValue, id: "bm_folder"), index: nil))
        let url = try #require(URL(string: "https://example.com/work"))
        try tree.apply(.create(.bookmark("Work docs", url: url, in: "bm_folder", id: "bm_url"), index: nil))
        services.bookmarks.trees["default"] = tree
        let resolver = BookmarkResolver(services: services)
        let named = try BookmarkIconHandlers.folder(ActionInvocation(arguments: ["bookmark": .string("work")]), resolver)
        #expect(named.id == "bm_folder")
        #expect(throws: (any Error).self) {
            try BookmarkIconHandlers.folder(ActionInvocation(arguments: ["bookmark": .string("bm_url")]), resolver)
        }
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
