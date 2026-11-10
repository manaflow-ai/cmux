import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBookmarks
import Foundation
import Testing

/// The home daemon (`bookmarks-v1`) is the only bookmark writer and holds the only tree
/// (layer-ownership.md V-11). Before it serves bookmarks an edit is refused with the capability
/// gate's own text, nothing shows and no file is written; the app keeps no tree a refused edit could
/// go into.
@MainActor @Suite(.serialized)
struct BookmarkDaemonOnlyTests {
    typealias JSONValue = BookmarkRoutedClient.JSONValue

    @Test func anEditBeforeTheHomeDaemonServesBookmarksIsRefusedAndWritesNoFile() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "bookmark-daemon-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmarks = services.bookmarks
        bookmarks.start(directory: directory, importStore: nil)
        #expect(!bookmarks.usesDaemon, "no home daemon is connected in this test")

        let url = try #require(URL(string: "https://example.com/"))
        await #expect(throws: BookmarkService.Unavailable.self) {
            try await bookmarks.apply([.create(id: BookmarkID.make(), profile: "default", parent: BookmarkRoot.bar.rawValue,
                                               folder: false, title: "Example", url: url)])
        }
        #expect(!bookmarks.statuses.knows("default"), "a refused edit shows nowhere")
        #expect(bookmarks.bookmarkIDs(for: url, profile: "default") == nil, "the star's state stays unknown")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "bookmarks.json").path))
    }

    @MainActor private final class Shown {
        var notices: [String] = []
    }

    /// Delete Bookmark from a bar's context menu (or the palette) while the home daemon does not
    /// serve bookmarks: nobody awaits the run, so its failure shows as a refusal. It used to be
    /// tracked only for a capturing caller and dropped, so the menu item did nothing.
    @Test func deleteBookmarkFromAMenuWithTheDaemonDownShowsTheRefusal() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(!services.bookmarks.usesDaemon, "no home daemon is connected in this test")
        let expected = BookmarkAppStrings.failure(services.bookmarks.unavailable)
        let shown = Shown()
        let shows = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in
            if !quiet { shown.notices.append(reason) }
            shows?(reason, quiet)
        }
        defer { services.registry.refusalObserver = shows }
        let menu = ActionInvocation(target: ActionTargetRef(kind: .bookmark, id: "bm_row"))

        // A CLI or MCP run captures the work and gets the failure itself; no notice shows.
        let work = services.registry.capturingWork { _ = services.registry.perform("bookmark.remove", invocation: menu) }
        #expect(work.count == 1)
        #expect(await work.first?.value?.message == expected)
        #expect(shown.notices.isEmpty, "a capturing caller reports the failure itself")

        #expect(services.registry.perform("bookmark.remove", invocation: menu))
        let deadline = ContinuousClock.now + .seconds(5)
        while shown.notices.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shown.notices == [expected])
    }

    /// The star's next bookmark goes to the last folder used only while the daemon still has it:
    /// one deleted since (the daemon refuses its id with reason `invalid`, which no catch matched)
    /// gives the bar, and the folder is forgotten. A live one is kept; a root asks nothing.
    @Test func aDeletedLastFolderGivesTheBarAndIsForgotten() async throws {
        _ = NSApplication.shared
        let bookmarks = AppServices(environment: AppEnvironment.current([:])).bookmarks
        var asked: [String] = []
        bookmarks.lastFolder["default"] = "bm_gone"
        let gone = try await bookmarks.starFolder(profile: "default") { asked.append($0); return false }
        #expect(gone == BookmarkRoot.bar.rawValue)
        #expect(bookmarks.lastFolder["default"] == nil, "the deleted folder is not offered again")

        bookmarks.lastFolder["default"] = "bm_live"
        let live = try await bookmarks.starFolder(profile: "default") { asked.append($0); return true }
        #expect(live == "bm_live")
        #expect(bookmarks.lastFolder["default"] == "bm_live")

        bookmarks.lastFolder["default"] = BookmarkRoot.other.rawValue
        let other = try await bookmarks.starFolder(profile: "default") { asked.append($0); return false }
        #expect(other == BookmarkRoot.other.rawValue)
        bookmarks.lastFolder["default"] = nil
        let none = try await bookmarks.starFolder(profile: "default") { asked.append($0); return false }
        #expect(none == BookmarkRoot.bar.rawValue)
        #expect(asked == ["bm_gone", "bm_live"], "a root is never looked up")
    }

    /// The bubble's Remove on a page with 300 links: `bookmarks.apply` refuses more than 256 ops
    /// whole, so the deletes go as 256 then 44, in order, each after the one before answered, and a
    /// refusal stops the rest.
    @Test func threeHundredDuplicatesDeleteInBatchesOf256And44() async throws {
        let ops = (0..<300).map { BookmarkRoutedClient.Op.delete(id: "bm_dup_\($0)") }
        var sent: [[BookmarkRoutedClient.Op]] = []
        try await BookmarkRoutedClient.inBatches(ops) { sent.append($0) }
        #expect(sent.map(\.count) == [256, 44])
        #expect(sent.flatMap { $0 } == ops, "the deletes keep their order")

        struct Refused: Error {}
        var tries = 0
        var refused = false
        do { try await BookmarkRoutedClient.inBatches(ops) { _ in tries += 1; throw Refused() } } catch is Refused { refused = true }
        #expect(refused)
        #expect(tries == 1, "a refused batch stops the rest")
    }

    /// Review F1 (P1): an older build's 20,000-bookmark file (past 4 MiB as one request) goes as
    /// ordered batches, each under the byte budget and 256 rows, parents before children.
    @Test func aTwentyThousandBookmarkFileMigratesInBoundedOrderedBatches() throws {
        var rows: [JSONValue] = []
        var folder = ""
        for n in 0..<20_000 {
            let id = "bm_" + String(repeating: "0", count: 32 - String(n, radix: 16).count) + String(n, radix: 16)
            if n % 200 == 0 {
                rows.append(["id": .string(id), "parent": "bar", "kind": "folder", "title": .string("Folder \(n)"),
                             "created_ms": 1_700_000_000_000])
                folder = id
                continue
            }
            var row: [String: JSONValue] = [
                "id": .string(id), "parent": .string(folder), "kind": "url", "title": .string("Bookmark \(n) with a longer title"),
                "url": .string("https://example.test/\(n)/a/somewhat/long/path?q=\(n)"), "created_ms": 1_700_000_000_000,
            ]
            if n.isMultiple(of: 3) { row["last_used_ms"] = 1_700_000_000_001 }
            rows.append(.object(row))
        }
        let document = try JSONEncoder().encode(JSONValue.object(["version": 1, "profiles": ["default": .array(rows)]]))
        let cap = 4 * 1024 * 1024
        #expect(document.count > cap, "the fixture is past the cap as one request")

        let batches = try BookmarkRoutedClient.legacyBatches(document)
        #expect(batches.count == (20_000 + 255) / 256)
        for batch in batches {
            #expect(batch.nodes.count <= BookmarkRoutedClient.maxOps)
            let request: JSONValue = [
                "protocol": "cmux.protocol/2", "type": "request", "id": .string(UUID().uuidString),
                "operation": "bookmarks.import_legacy_file", "idempotency_key": .string(UUID().uuidString.lowercased()),
                "params": .object(batch.params),
            ]
            let bytes = try JSONEncoder().encode(request).count
            #expect(bytes <= BookmarkRoutedClient.legacyBatchBytes + 1024, "a batch of \(bytes) bytes")
            #expect(bytes < cap)
        }
        let sent = batches.flatMap(\.nodes)
        #expect(sent.map { $0["id"] } == rows.map { $0["id"] }, "the file's order")
        var seen: Set<String> = ["bar", "other"]
        for node in sent {
            #expect(seen.contains(node["parent"]?.stringValue ?? ""), "a parent goes before its children")
            seen.insert(node["id"]?.stringValue ?? "")
        }
        #expect(sent[2]["index"] == 1, "each row has its index among its siblings")
        #expect(sent[200]["index"] == 1, "the second folder is the bar's second child")
        #expect(throws: (any Error).self) { try BookmarkRoutedClient.legacyBatches(Data("not json".utf8)) }
    }
}
