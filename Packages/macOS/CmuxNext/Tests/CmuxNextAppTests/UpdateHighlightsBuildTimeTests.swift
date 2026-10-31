import Foundation
@testable import CmuxNextUpdater
import Testing

/// The Updated card names the build by when it was made and by its commit (Leo 2026-10-26: "it
/// just says updated to nightly, but that doesn't mean anything"). ``UpdateHighlights`` carries
/// both to the page: the notes' `builtAt` and `head`, else the appcast item's date when it has a
/// time of day. A record saved before these fields still decodes.
@Suite struct UpdateHighlightsBuildTimeTests {
    static let head = "a9d1434de781a18ebae84d93d2b5a803864f5839"

    static func notes(builtAt: String? = nil, head: String? = nil) -> ReleaseNotes {
        ReleaseNotes(version: 1, build: "4037004604601", shortVersion: "1.0.0-nightly.4037004604601", date: "2026-10-26",
                     highlights: [], changes: [], head: head, builtAt: builtAt)
    }

    static func highlights(notes: ReleaseNotes?, appcast: UpdateChangelog?) -> UpdateHighlights {
        UpdateHighlights(version: "1.0.0-nightly.4037004604601", build: "4037004604601", fromVersion: "1.0.0-nightly.1",
                         fromBuild: "1", notes: notes, appcast: appcast, languages: ["en"])
    }

    @Test func theNotesGiveTheTimeAndTheCommit() {
        let shown = Self.highlights(notes: Self.notes(builtAt: "2026-10-26T19:38:52Z", head: Self.head), appcast: nil)
        #expect(shown.builtAt == "2026-10-26T19:38:52Z")
        #expect(shown.head == Self.head)
        #expect(shown.date == "2026-10-26")
    }

    @Test func withoutThemTheAppcastDateGivesTheTime() {
        let pubDate = Date(timeIntervalSince1970: 1_793_043_532) // 2026-10-26T19:38:52Z
        let shown = Self.highlights(notes: Self.notes(), appcast: UpdateChangelog(version: nil, date: pubDate, lines: []))
        #expect(shown.builtAt == "2026-10-26T19:38:52Z")
        #expect(shown.head == nil)
    }

    @Test func aDayFromTheNotesIsNotATime() throws {
        let fromNotes = UpdateChangelog(notes: Self.notes(), version: nil)
        #expect(fromNotes.date != nil)
        #expect(Self.highlights(notes: nil, appcast: fromNotes).builtAt == nil)
    }

    @Test func notesAndRecordsFromBeforeTheFieldsStillDecode() throws {
        let notes = #"{"version":1,"build":"1","shortVersion":"1.0.0","date":"2026-10-26","highlights":[],"changes":[]}"#
        let decoded = try JSONDecoder().decode(ReleaseNotes.self, from: Data(notes.utf8))
        #expect(decoded.head == nil && decoded.builtAt == nil)
        let withFields = #"{"version":1,"build":"1","shortVersion":"1.0.0","date":"2026-10-26","highlights":[],"changes":[],"head":"abc","builtAt":"2026-10-26T19:38:52Z"}"#
        let both = try JSONDecoder().decode(ReleaseNotes.self, from: Data(withFields.utf8))
        #expect(both.head == "abc" && both.builtAt == "2026-10-26T19:38:52Z")
        let record = #"""
        {"version": "1.0.0", "build": "1", "fromVersion": "0.9.0", "fromBuild": "0", "source": "none",
         "language": "en", "items": [], "moreCount": 0, "changelog": {"from": "0.9.0", "to": "1.0.0"}}
        """#
        let highlights = try JSONDecoder().decode(UpdateHighlights.self, from: Data(record.utf8))
        #expect(highlights.builtAt == nil && highlights.head == nil && highlights.pulled == nil)
    }
}
