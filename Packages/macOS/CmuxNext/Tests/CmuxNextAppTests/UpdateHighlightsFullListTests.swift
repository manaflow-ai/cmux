import Foundation
@testable import CmuxNextUpdater
import Testing

/// The Update Ready card's hover popover scrolls to the update's whole change list (2026-10-20:
/// "the changelog hover card must scroll to the full list of changes"). The top three keep their
/// place in ``UpdateHighlights/items``; every other change is in ``UpdateHighlights/rest``.
/// A record saved before `rest` existed still decodes.
@Suite struct UpdateHighlightsFullListTests {
    @Test func everyChangePastTheTopThreeIsInTheRest() {
        let lines = (1...8).map { ReleaseNotes.SummaryLine(group: $0 % 2 == 0 ? "fixed" : "new", title: "Change \($0)") }
        let notes = ReleaseNotes(version: 1, build: "42", shortVersion: "1.0.0-nightly.42", date: "2026-10-20",
                                 highlights: [], changes: [], whatsNew: nil, summary: lines)
        let highlights = UpdateHighlights(version: "1.0.0-nightly.42", build: "42", fromVersion: "1.0.0-nightly.41",
                                          fromBuild: "41", notes: notes, appcast: nil, languages: ["en"])
        #expect(highlights.items.map(\.title) == ["Change 1", "Change 2", "Change 3"])
        #expect(highlights.rest?.map(\.title) == (4...8).map { "Change \($0)" })
        #expect(highlights.moreCount == 5)
    }

    @Test func aRecordSavedBeforeTheRestExistedStillDecodes() throws {
        let json = #"""
        {"version": "1.0.0", "build": "1", "fromVersion": "0.9.0", "fromBuild": "0", "source": "summary",
         "language": "en", "items": [{"id": "a", "title": "A", "category": "new"}], "moreCount": 4,
         "changelog": {"from": "0.9.0", "to": "1.0.0"}}
        """#
        let decoded = try JSONDecoder().decode(UpdateHighlights.self, from: Data(json.utf8))
        #expect(decoded.items.count == 1)
        #expect(decoded.rest == nil)
    }
}
