import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBookmarks
import CmuxNextDaemon
import Foundation
import Testing

/// Bookmark folders carry an icon (`bookmark-icon-v1`, cx-qno.11.3), the shared icon string: an
/// emoji, an SF Symbol name or a stored image or SVG asset of the home daemon. The daemon's record
/// carries it into the app's tree, the bookmarks bar and the manager page draw it in place of the
/// folder symbol (the folder symbol stands in while a stored asset loads), and Set/Remove Folder
/// Icon are bookmark actions for the palette, the right-click menus, the CLI and MCP.
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

    @Test func theManagerDrawsAFoldersEmojiOrStoredIcon() throws {
        let services = Self.services()
        let manager = BookmarkManagerSourceAdapter(services: services, tabKey: "bookmark-folder-icon-test")
        #expect(manager.favicon(for: try Self.folder(nil)) == nil, "a folder without an icon draws the folder symbol")
        #expect(manager.favicon(for: try Self.folder("🚀")) != nil, "an emoji folder icon draws in its own colors")
        #expect(manager.favicon(for: try Self.folder(Self.asset)) == nil, "the folder symbol stands in while the asset loads")
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
