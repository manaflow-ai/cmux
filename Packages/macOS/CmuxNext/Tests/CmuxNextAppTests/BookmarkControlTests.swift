import AppKit
@testable import CmuxNextApp
import CmuxNextBookmarks
import CmuxNextBrowserImport
import CmuxNextSettings
import Foundation
import Testing

/// The two facts `cmux setup browser-import` reads from the app: whether
/// `bookmark.list` answered from the daemon's stored tree or not yet, and which
/// source keys `bookmark.importFromBrowser` would use for a browser and profile
/// (`bookmark.importSources`).
@MainActor @Suite(.serialized)
struct BookmarkControlTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    static func profile(_ browser: ImportBrowser, _ folder: String, _ name: String,
                        _ bookmarks: DataAvailability = .available) -> BrowserSourceProfile {
        BrowserSourceProfile(browser: browser, directoryName: folder, displayName: name,
                             path: URL(fileURLWithPath: "/tmp/\(browser.rawValue)/\(folder)"), availability: [.bookmarks: bookmarks])
    }

    static let fixture = [
        BrowserSource(browser: .chrome, appURL: nil, profiles: [
            profile(.chrome, "Default", "Work"), profile(.chrome, "Profile 1", "Home"),
            profile(.chrome, "Profile 2", "Locked", .needsFullDiskAccess),
        ]),
        BrowserSource(browser: .brave, appURL: nil, profiles: [profile(.brave, "Default", "Person 1")]),
    ]

    /// The `sources` rows of an answer, each as its `source_key`.
    static func keys(_ value: JSONValue) -> [String] {
        rows(value).compactMap { $0["source_key"]?.stringValue }
    }

    static func rows(_ value: JSONValue) -> [[String: JSONValue]] {
        guard let sources = value["sources"]?.arrayValue else {
            Issue.record("no sources array in \(value)")
            return []
        }
        return sources.compactMap(\.objectValue)
    }

    /// Before the home daemon serves bookmarks the list says so instead of passing for "no
    /// bookmarks": the app has no copy of the tree to answer from.
    @Test func listSaysTheTreeIsNotLoadedYet() async throws {
        let services = Self.services()
        let reply = try #require(try await BookmarkControl.list(services, ["profile": .string("default")]).objectValue)
        #expect(reply["loaded"] == .bool(false))
        #expect(reply["storage"] == .string("daemon"))
        #expect(reply["bookmarks"] == .array([]))
    }

    /// A search row's `index` and `path` are the daemon's: its place in the stored tree (#37375's
    /// follow-up, where they came from a copy that could lag it).
    @Test func aRowsIndexAndPathAreTheDaemons() throws {
        let json = #"{"id":"bm_a","parent":"bm_work","kind":"url","title":"Docs","url":"https://example.com/","index":3,"path":["bar","Work"],"created_ms":0}"#
        let node = try JSONDecoder().decode(BookmarkNode.self, from: Data(json.utf8))
        let row = BookmarkControl.json(node)
        #expect(row["index"] == .number(3))
        #expect(row["path"] == .string("bar/Work"))
    }

    /// Every readable profile of the named browser, keyed as the import keys its folder.
    @Test func importSourcesNamesWhatTheImportWouldRead() {
        let answer = BookmarkControl.importSources(Self.fixture, browser: "chrome", source: nil)
        #expect(Self.keys(answer) == ["chrome/Default", "chrome/Profile 1"])
        #expect(Self.keys(answer) == BookmarkBrowserImport.match(Self.fixture, browser: "chrome", source: nil).map(\.id))
        let first = Self.rows(answer).first
        #expect(first?["browser"] == .string("chrome"))
        #expect(first?["folder"] == .string("Default"))
        #expect(first?["name"] == .string("Work"))
    }

    /// `source` matches a profile folder or name, any case; the browser may be its product name.
    @Test func importSourcesNarrowsToOneProfile() {
        #expect(Self.keys(BookmarkControl.importSources(Self.fixture, browser: "chrome", source: "home")) == ["chrome/Profile 1"])
        let brave = ImportBrowser.brave.displayName
        #expect(Self.keys(BookmarkControl.importSources(Self.fixture, browser: brave, source: "default")) == ["brave/Default"])
    }

    /// A blocked profile, an unknown profile or browser: nothing the import would read.
    @Test func importSourcesIsEmptyForWhatTheImportWouldSkip() {
        #expect(Self.keys(BookmarkControl.importSources(Self.fixture, browser: "chrome", source: "Locked")).isEmpty)
        #expect(Self.keys(BookmarkControl.importSources(Self.fixture, browser: "chrome", source: "Nobody")).isEmpty)
        #expect(Self.keys(BookmarkControl.importSources(Self.fixture, browser: "firefox", source: nil)).isEmpty)
    }
}
