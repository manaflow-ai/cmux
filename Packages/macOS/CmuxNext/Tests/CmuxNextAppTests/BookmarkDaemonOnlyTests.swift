import AppKit
@testable import CmuxNextApp
import CmuxNextBookmarks
import CmuxNextBrowserImport
import CmuxNextDaemon
import Foundation
import Testing

/// The home daemon (`bookmarks-v1`) is the only bookmark writer. Before it serves bookmarks, an
/// edit is refused, nothing is written (#31842), and every surface says why with the capability
/// gate's own localized text: still starting, could not start, or out of date. Never the raw
/// "not connected to cmux-tui", and never silence (the bookmarks bar and the palette used `try?`).
@MainActor @Suite(.serialized)
struct BookmarkDaemonOnlyTests {
    private static func started() -> (AppServices, BookmarkService, URL) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "bookmark-daemon-only-\(UUID().uuidString)")
        services.bookmarks.start(directory: directory, importStore: nil)
        return (services, services.bookmarks, directory)
    }

    private static func page() throws -> BookmarkNode {
        BookmarkNode.bookmark("Example", url: try #require(URL(string: "https://example.com/")), in: BookmarkRoot.bar.rawValue)
    }

    /// The capability gate's text for bookmarks on this machine (the same text every other surface shows).
    private static func gateText(_ services: AppServices) -> String {
        services.machines.local.missingCapabilityMessage(DaemonCapability.bookmarks.rawValue)
    }

    @Test func anEditBeforeTheHomeDaemonServesBookmarksIsRefusedAndWritesNoFile() throws {
        let (_, bookmarks, directory) = Self.started()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!bookmarks.usesDaemon, "no home daemon is connected in this test")

        let page = try Self.page()
        #expect(throws: (any Error).self) { try bookmarks.apply(.create(page, index: nil), profile: "default") }
        #expect(bookmarks.tree("default").isEmpty, "a refused edit shows nowhere")
        #expect(!bookmarks.isLoaded("default"), "only the daemon's reply makes a tree loaded")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "bookmarks.json").path))
    }

    /// The text a person reads is the gate's, not "Bookmark error: not connected to cmux-tui".
    @Test func theRefusalReadsAsTheCapabilityGateText() throws {
        let (services, bookmarks, directory) = Self.started()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try bookmarks.apply(.create(try Self.page(), index: nil), profile: "default")
            Issue.record("the edit must be refused before the home daemon serves bookmarks")
        } catch {
            let text = BookmarkAppStrings.failure(error)
            #expect(text == Self.gateText(services))
            #expect(!text.contains("not connected to cmux-tui"))
        }
    }

    /// A link dropped on the bookmarks bar and a bookmark moved there show the refusal instead of nothing.
    @Test func theBookmarksBarShowsItsRefusal() throws {
        let (services, bookmarks, directory) = Self.started()
        defer { try? FileManager.default.removeItem(at: directory) }
        var refusals: [String] = []
        services.registry.refusalObserver = { reason, _ in refusals.append(reason) }
        defer { services.registry.refusalObserver = nil }
        let bar = BookmarkBarSourceAdapter(service: bookmarks, tabKey: "bookmark-daemon-only-test")
        bar.addToBar(url: try #require(URL(string: "https://example.com/")), title: "Example", index: 0)
        bar.moveToBar(BookmarkID.make(), index: 0)
        #expect(refusals == [Self.gateText(services), Self.gateText(services)])
    }

    /// Remove Imported Browser Data with no home daemon: the real sink must refuse (the gate's text),
    /// not find no folder in an empty tree and report success, which let the saved import be deleted
    /// while the bookmarks stayed in the daemon (review of #32110, B1).
    @Test func removingImportedBookmarksWithNoHomeDaemonIsRefused() async throws {
        let (services, _, directory) = Self.started()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = try #require(services.importedBookmarkSink)
        let source = ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                        proposedProfileID: "default", targetProfileID: "default")
        await #expect(throws: BookmarkError.unavailable(message: Self.gateText(services))) {
            try await sink.replaceImportedBookmarks([], source: source)
        }
    }

    /// Imports saved before bookmarks existed: a pass refused for want of the home daemon writes no
    /// done-marker, so it runs again once the daemon serves bookmarks.
    @Test func aLegacyImportPassRefusedForWantOfTheDaemonRunsAgain() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "bookmark-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedDataStore(directory: directory.appending(path: "imports"))
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Google Chrome",
                                                           proposedProfileID: "default", targetProfileID: "default"), kinds: [.bookmarks])
        batch.bookmarks = [ImportedBookmark(title: "A", url: try #require(URL(string: "https://a.example/")))]
        _ = try await store.save(batch)
        services.bookmarks.start(directory: directory, importStore: store)
        await services.bookmarks.migrateLegacyImports()
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "bookmarks-imports-migrated").path))
    }
}
