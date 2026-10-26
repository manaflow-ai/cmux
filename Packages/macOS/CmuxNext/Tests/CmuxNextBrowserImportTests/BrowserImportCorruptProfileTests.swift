@testable import CmuxNextBrowserImport
import Foundation
import Testing

/// The damaged profiles the import fuzz (``BrowserImportFuzzTests``) is built to find, one each, as
/// plain regression tests: before p10-stability-025 the first three trapped (integer overflow), the next
/// two never ended, and the dates broke Chromium's Int64 time conversion where the password store and
/// the bookmark export write them. Gated like the fuzz: agents run them on the fleet, CI does not.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_IMPORT_FUZZ"] == "1",
        "set CMUX_IMPORT_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    ),
    .timeLimit(.minutes(1))
)
struct BrowserImportCorruptProfileTests {
    @Test func aFirefoxTabIndexAtIntMinPicksTheFirstEntry() throws {
        let json = Data(#"""
        {"windows":[{"tabs":[{"index":-9223372036854775808,"entries":[{"url":"https://a.example/"},{"url":"https://b.example/"}]},
        {"index":9223372036854775807,"entries":[{"url":"https://c.example/"},{"url":"https://d.example/"}]}]}]}
        """#.utf8)
        let tabs = FirefoxSessionReader().parse(MozLz4Fixture.file(json)).items
        #expect(tabs.map(\.url.absoluteString) == ["https://a.example/", "https://d.example/"])
    }

    @Test func exportedVisitCountsSaturateInsteadOfOverflowing() throws {
        let json = Data(#"""
        {"history":[{"url":"https://a.example/","time_usec":1700000000000000,"visit_count":9223372036854775807},
        {"url":"https://a.example/","time_usec":1700000001000000,"visit_count":9223372036854775807},
        {"url":"https://c.example/","time_usec":1700000002000000,"visit_count":-5}]}
        """#.utf8)
        let history = try #require(ExportedHistory(json: json))
        let counts = Dictionary(uniqueKeysWithValues: history.entries.map { ($0.url.host() ?? "", $0.visitCount) })
        // A negative count reads as one visit (ExportedHistory's floor), the sum of two Int.max as the cap.
        #expect(counts == ["a.example": ImportedHistoryEntry.maximumVisitCount, "c.example": 1])
        #expect(history.skipped.total == 0)
    }

    /// Before: a time past year 9999 became a 1970 visit in an export, and vanished uncounted from a database.
    @Test func historyRowsWithCorruptTimesAreSkippedAndCounted() throws {
        let json = Data(#"""
        {"history":[{"url":"https://a.example/","time_usec":1700000000000000},{"url":"https://b.example/","time_usec":1e300},
        {"url":"https://c.example/","time_usec":-1e20},{"url":"https://d.example/"},{"url":"chrome://flags","time_usec":1700000000000000}]}
        """#.utf8)
        let history = try #require(ExportedHistory(json: json))
        #expect(history.entries.map(\.url.absoluteString) == ["https://a.example/"])
        #expect(history.skipped.badTime == 3 && history.skipped.notImportable == 1 && history.skipped.total == 4)

        // Ten pages at Int64.max sort first under ORDER BY … DESC; they must not take the limit's places.
        let root = FileManager.default.temporaryDirectory.appending(path: "chromium-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "History")
        let visit = Int64((ImportFuzzCases.now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let corrupt = (0..<10).map { "('https://bad\($0).example/', 'Bad', 1, 0, \(Int64.max), 0)" }
        try SQLiteFixture.create(file, """
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url, title, visit_count, typed_count, last_visit_time, hidden);
            INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES
              \(corrupt.joined(separator: ", ")), ('https://good.example/', 'Good', 2, 0, \(visit), 0), ('about:blank', '', 1, 0, \(visit), 0);
            """)
        let read = try ChromiumHistoryReader().read(file, limit: 5)
        #expect(read.items.map(\.url.absoluteString) == ["https://good.example/"])
        #expect(read.skipped.badTime == 10 && read.skipped.notImportable == 1)
    }

    @Test func profileFoldersNumberedUpToIntMaxStillSort() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chromium-profiles-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Profile 9223372036854775807", "Profile 2", "Default", "Guest"]
        for name in names {
            try FileManager.default.createDirectory(at: root.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        let cache = names.map { "\"\($0)\":{\"name\":\"\($0)\"}" }.joined(separator: ",")
        try Data(#"{"profile":{"info_cache":{\#(cache)}}}"#.utf8).write(to: root.appending(path: "Local State"))
        let entries = ChromiumProfileList().entries(in: root)
        #expect(entries.map(\.directoryName) == ["Default", "Profile 2", "Profile 9223372036854775807", "Guest"])
    }

    /// Before: each copy of the list was walked again, 2^64 times by the depth limit alone.
    @Test func anArcListThatHoldsItselfIsReadOnce() throws {
        let json = Data(#"""
        {"sidebar":{"containers":[{"spaces":["s1",{"id":"s1","title":"Home","profile":{"default":true},"containerIDs":["pinned","p1"]}],
        "items":["p1",{"id":"p1","childrenIds":["l1"]},"l1",{"id":"l1","title":"List","data":{"list":{}},"childrenIds":["l1","l1","t1"]},
        "t1",{"id":"t1","data":{"tab":{"savedURL":"https://arc.net/"}}}]}]}}
        """#.utf8)
        let read = try ArcSidebarReader().parse(json, profileDirectory: "Default")
        #expect(read.items.map(\.folderPath) == [["Home", "List"]])
        #expect(read.skipped.repeatedFolder == 2 && read.skipped.total == 2)
    }

    /// Before: a 1 KB binary plist that names each folder twice from its parent was walked 2^31 times
    /// (later capped at 2^20 entries, still ~500K duplicate bookmarks). Each folder is read once now.
    @Test func safariBookmarksThatShareFoldersAreReadOnce() throws {
        let read = try SafariBookmarksParser().parse(BinaryPlistFixture.doublingBookmarks(levels: 30))
        // One chain of 31 folders down to the two leaves; the second mention at each of 30 levels is counted.
        #expect(read.items.count == 2)
        #expect(read.items.allSatisfy { $0.url.absoluteString == "https://example.com/" && $0.folderPath.count == 31 })
        #expect(read.skipped.repeatedFolder == 30 && read.skipped.total == 30)
    }

    @Test func timesThatBaseTimeCannotHoldAreDropped() {
        let time = BrowserTime()
        #expect(time.chromium(.max) == nil)
        #expect(time.mozilla(.max) == nil)
        #expect(time.cocoa(1e300) == nil)
        #expect(time.unix(.nan) == nil)
        #expect(time.unix(-1e20) == nil)
        #expect(time.chromium(13_300_000_000_000_000) != nil)
        #expect(time.chromium(BrowserTime.lastChromium) != nil && time.chromium(BrowserTime.lastChromium + 1_000_000) == nil)
        #expect(time.mozilla(BrowserTime.lastMozilla) != nil && time.mozilla(BrowserTime.lastMozilla + 1_000_000) == nil)
        #expect(time.cocoa(Double(BrowserTime.lastCocoa)) != nil && time.cocoa(Double(BrowserTime.lastCocoa + 1)) == nil)
        // An expiry keeps its cookie persistent.
        #expect(time.chromiumExpiry(.max) == BrowserTime.lastKept)
        #expect(time.cocoaExpiry(.infinity) == BrowserTime.lastKept)
        #expect(time.cocoaExpiry(.nan) == nil)
        #expect(FirefoxCookieReader().expiry(.max) == BrowserTime.lastKept)
    }
}
