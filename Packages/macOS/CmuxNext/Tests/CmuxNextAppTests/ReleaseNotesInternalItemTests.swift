import CmuxNextUpdater
import Foundation
import Testing

/// The notes mark a commit that touches only CI or tooling files `"internal": true`
/// (release-notes.py `tooling_only`; nightly 4037632091801 read "Fixed: validate release
/// headings within their day"). The app decodes the notes and encodes them again for the
/// page (`cmux.changelog.get`), so the flag must survive the round trip.
struct ReleaseNotesInternalItemTests {
    @Test func theInternalFlagSurvivesDecodeAndEncode() throws {
        let json = #"""
        {"version":1,"build":"10","shortVersion":"1.0.0-nightly.10","date":"2026-10-26","highlights":[],
         "changes":["fix(sidebar): rows keep their order (#3)","fix(changelog): validate release headings within their day (#2)"],
         "items":[{"title":"fix(sidebar): rows keep their order","author":"Ada","pr":3},
                  {"title":"fix(changelog): validate release headings within their day","author":"Ada","pr":2,"internal":true}]}
        """#
        let notes = try JSONDecoder().decode(ReleaseNotes.self, from: Data(json.utf8))
        #expect(notes.changeItems.map(\.isInternal) == [nil, true])
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes)) as? [String: Any]
        let items = try #require(again?["items"] as? [[String: Any]])
        #expect(items[0]["internal"] == nil)
        #expect(items[1]["internal"] as? Bool == true)
    }
}
