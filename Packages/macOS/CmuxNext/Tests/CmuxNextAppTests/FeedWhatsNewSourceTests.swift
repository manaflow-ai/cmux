import Foundation
@testable import CmuxNextUpdater
import Testing

@Suite struct FeedWhatsNewSourceTests {
    private let date = "2026-10-17T02:58:43Z"

    @Test(arguments: [true, false])
    func embeddedPRLinkSurvivesReleaseNotesRoundTrip(hasPR: Bool) throws {
        let pr = "https://github.com/manaflow-ai/cmux/pull/27919"
        var entry: [String: Any] = [
            "id": "linked", "category": "improved", "title": ["en": "A clearer sidebar"],
            "summary": ["en": "Find related workspaces together."],
            "platforms": ["macos"], "audience": "all",
            "tryIt": ["action": "palette.checkForUpdates"], "docs": "https://cmux.com/docs/updates",
        ]
        if hasPR { entry["pr"] = pr }
        let wire: [String: Any] = [
            "version": 1, "build": "42", "shortVersion": "1.0.0-nightly.42", "date": date,
            "highlights": [], "changes": [],
            "whatsNew": ["schemaVersion": 1, "version": "1.0.0-nightly.42", "channel": "nightly",
                         "date": date, "headline": ["en": "A clearer sidebar"], "entries": [entry]],
        ]
        let notes = try JSONDecoder().decode(ReleaseNotes.self, from: JSONSerialization.data(withJSONObject: wire))
        let document = try #require(FeedWhatsNewSource.document(from: notes))
        let decoded = try #require(document.entries.first)
        #expect(decoded.pr?.absoluteString == (hasPR ? pr : nil))
        #expect(decoded.tryIt?.action == "palette.checkForUpdates")
        #expect(decoded.docs?.absoluteString == "https://cmux.com/docs/updates")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(notes)) as? [String: Any])
        let digest = try #require(encoded["whatsNew"] as? [String: Any])
        let entries = try #require(digest["entries"] as? [[String: Any]])
        #expect(entries.first?["pr"] as? String == (hasPR ? pr : nil))
    }

    @Test func embeddedDigestWinsAndKeepsItsEntries() throws {
        let embedded = WhatsNewDocument(
            version: "1.0.0-nightly.42",
            channel: .nightly,
            date: date,
            headline: "Reviewed digest",
            entries: [WhatsNewDocument.Entry(id: "reviewed", category: .fixed, title: "Reviewed", summary: "Reviewed")]
        )
        let notes = makeNotes(shortVersion: embedded.version, highlights: [highlight(category: "new")], summary: [summary(group: "new")], whatsNew: embedded)

        let document = try #require(FeedWhatsNewSource.document(from: notes))
        #expect(document.origin == .feed)
        #expect(document == embedded.withOrigin(.feed))
    }

    @Test func highlightsBecomeEntriesWithTheirCategories() throws {
        let notes = makeNotes(
            highlights: [highlight(id: "new", category: "new"), highlight(id: "better", category: "improved"), highlight(id: "fixed", category: "fixed"), highlight(id: "secure", category: "security")]
        )

        let document = try #require(FeedWhatsNewSource.document(from: notes))
        #expect(document.entries.map(\.category) == [.new, .improved, .fixed, .security])
    }

    @Test func summaryProvidesFallbackWhenHighlightsAndDigestAreMissing() throws {
        let notes = makeNotes(highlights: [], summary: [summary(group: "new", title: "A new route"), summary(group: "changed", title: "A smoother flow"), summary(group: "fixed", title: "A fixed bug")])

        let document = try #require(FeedWhatsNewSource.document(from: notes))
        #expect(document.entries.map(\.id) == ["summary-0", "summary-1", "summary-2"])
        #expect(document.entries.map(\.category) == [.new, .improved, .fixed])
        #expect(document.headline.resolved(for: ["en"]) == "A new route")
    }

    @Test func emptySummaryDoesNotCreateAPlaceholderDocument() {
        let notes = makeNotes(highlights: [], summary: [summary(group: "new", title: "   "), summary(group: "fixed", title: "")])
        #expect(FeedWhatsNewSource.document(from: notes) == nil)
    }

    private func makeNotes(shortVersion: String = "1.0.0-nightly.42", highlights: [ReleaseNotes.Highlight], summary: [ReleaseNotes.SummaryLine] = [], whatsNew: WhatsNewDocument? = nil) -> ReleaseNotes {
        ReleaseNotes(version: 1, build: "42", shortVersion: shortVersion, date: date, highlights: highlights, changes: [], whatsNew: whatsNew, summary: summary)
    }

    private func highlight(id: String = "highlight", category: String?) -> ReleaseNotes.Highlight {
        ReleaseNotes.Highlight(id: id, title: id.capitalized, body: "Details for \(id).", media: [], action: nil, category: category)
    }

    private func summary(group: String, title: String = "A summary line") -> ReleaseNotes.SummaryLine {
        ReleaseNotes.SummaryLine(group: group, title: title)
    }
}

private extension WhatsNewDocument {
    func withOrigin(_ origin: Origin) -> WhatsNewDocument {
        var copy = self
        copy.origin = origin
        return copy
    }
}
