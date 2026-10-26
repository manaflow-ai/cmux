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
        let tabs = FirefoxSessionReader().parse(MozLz4Fixture.file(json))
        #expect(tabs.map(\.url.absoluteString) == ["https://a.example/", "https://d.example/"])
    }

    @Test func exportedVisitCountsSaturateInsteadOfOverflowing() throws {
        let json = Data(#"""
        {"history":[{"url":"https://a.example/","time_usec":1700000000000000,"visit_count":9223372036854775807},
        {"url":"https://a.example/","time_usec":1700000001000000,"visit_count":9223372036854775807},
        {"url":"https://b.example/","time_usec":1e300,"visit_count":-5}]}
        """#.utf8)
        let history = try #require(ExportedHistory(json: json))
        let counts = Dictionary(uniqueKeysWithValues: history.entries.map { ($0.url.host() ?? "", $0.visitCount) })
        // A negative count reads as one visit (ExportedHistory's floor), the sum of two Int.max as the cap.
        #expect(counts == ["a.example": ImportedHistoryEntry.maximumVisitCount, "b.example": 1])
        #expect(history.entries.allSatisfy { $0.lastVisit.timeIntervalSince1970.isFinite && $0.lastVisit.timeIntervalSince1970 < 253_402_300_800 })
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
        let bookmarks = try ArcSidebarReader().parse(json, profileDirectory: "Default")
        #expect(bookmarks.map(\.folderPath) == [["Home", "List"]])
    }

    /// Before: a 1 KB binary plist that names each folder twice from its parent was walked 2^31 times.
    @Test func safariBookmarksThatShareFoldersStopAtTheNodeLimit() throws {
        let bookmarks = try SafariBookmarksParser().parse(BinaryPlistFixture.doublingBookmarks(levels: 30))
        #expect(!bookmarks.isEmpty)
        #expect(bookmarks.count <= SafariBookmarksParser().maximumNodes)
        #expect(bookmarks.allSatisfy { $0.url.absoluteString == "https://example.com/" })
    }

    @Test func timesThatBaseTimeCannotHoldAreDropped() {
        let time = BrowserTime()
        #expect(time.chromium(.max) == nil)
        #expect(time.mozilla(.max) == nil)
        #expect(time.cocoa(1e300) == nil)
        #expect(time.unix(.nan) == nil)
        #expect(time.unix(-1e20) == nil)
        #expect(time.chromium(13_300_000_000_000_000) != nil)
        // An expiry keeps its cookie persistent.
        #expect(time.chromium(.max, clampingFuture: true) == BrowserTime.lastKept)
        #expect(time.cocoa(.infinity, clampingFuture: true) == BrowserTime.lastKept)
        #expect(time.cocoa(.nan, clampingFuture: true) == nil)
        #expect(FirefoxCookieReader().expiry(.max) == BrowserTime.lastKept)
    }
}
