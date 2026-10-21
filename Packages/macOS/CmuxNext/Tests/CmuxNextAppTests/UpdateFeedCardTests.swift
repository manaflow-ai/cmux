@testable import CmuxNextApp
@testable import CmuxNextFeed
import CmuxNextUpdater
import Foundation
import Testing

/// Installed updates in the Feed (Leo 2026-10-20): one notice per installed version of cmux or
/// an agent CLI, with the version it came from, its top changes, the rest's count and the notes.
@MainActor @Suite struct UpdateFeedCardTests {
    let at = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func oneCardPerInstalledVersionAndSubject() {
        let app = UpdateFeedCard(subject: .app, from: "1.0.0-nightly.1", to: "1.0.0-nightly.3947430561301", changes: ["a"], at: at)
        let claude = UpdateFeedCard(subject: .harness(id: "claude", name: "Claude Code"), from: "2.1.303", to: "2.1.305",
                                    changes: ["a"], at: at)
        #expect(app.dedupeKey == "update:app:1.0.0-nightly.3947430561301")
        #expect(claude.dedupeKey == "update:harness:claude:2.1.305")
        #expect(app.item.id == UpdateFeedCard(subject: .app, from: nil, to: app.to, changes: [], at: .now).item.id,
                "one version's card has two ids, so the Feed would show it twice")
        #expect(app.item.id != claude.item.id)
        #expect(app.item.id.hasPrefix("fi_") && app.item.id.count == 23)
        #expect(app.item.home == .local(install: "updates"), "an update card would travel through the cloud session")
        #expect(app.item.poster.kind == .app)
        #expect(claude.item.poster.kind == .harness)
        #expect(app.item.thread == "update:app")
        #expect(claude.item.thread == "update:harness:claude")
    }

    @Test func nightlyVersionsReadAsTheUpdateCardDoes() {
        #expect(UpdateFeedCard.readable("1.0.0-nightly.3947430561301") == "nightly 3947430")
        #expect(UpdateFeedCard.readable("2.1.305") == "2.1.305")
        #expect(UpdateFeedCard.readable("1.0.0-nightly.beta") == "1.0.0-nightly.beta")
        let card = UpdateFeedCard(subject: .app, from: nil, to: "1.0.0-nightly.3947430561301", changes: [], at: at)
        #expect(card.item.title == "cmux updated to nightly 3947430")
    }

    @Test func theBodyListsTheTopChangesAndCountsTheRest() {
        let changes = (1...8).map { "Change \($0)" } + ["- nested\n  - line"]
        let card = UpdateFeedCard(subject: .harness(id: "codex", name: "Codex"), from: "0.40.0", to: "0.42.0", changes: changes,
                                  unlisted: 2, notes: URL(string: "https://example.com/CHANGELOG.md"), at: at)
        let lines = card.body.components(separatedBy: "\n")
        #expect(lines.first == "From 0.40.0")
        #expect(lines.filter { $0.hasPrefix("- ") } == (1...5).map { "- Change \($0)" })
        #expect(lines.last == "6 more changes", "the rest's count left out the listed changes or the unlisted ones")
        #expect(!card.body.contains("https://"), "the plain-text body shows the notes link as raw Markdown")
        #expect(card.item.context.url?.absoluteString == "https://example.com/CHANGELOG.md")
        // Same from and to: no "From" line. A non-https notes URL is never the item's link.
        let local = UpdateFeedCard(subject: .app, from: "1.0.0", to: "1.0.0", changes: ["x"], notes: URL(string: "file:///etc/passwd"), at: at)
        #expect(local.body == "- x")
        #expect(local.item.context.url == nil)
        #expect(UpdateFeedCard.oneLine("- nested\n  - line") == "nested")
        #expect(UpdateFeedCard.oneLine("**Bold** change") == "**Bold** change")
        #expect(UpdateFeedCard.oneLine("* - two markers") == "two markers")
    }

    @Test func theAppCardComesFromTheUpdatedCardsHighlightsOnceTheyListChanges() throws {
        let notes = ReleaseNotes.debugFake(version: "1.0.0-nightly.200", changes: 7)
        let highlights = UpdateHighlights(version: "1.0.0-nightly.200", build: "200", fromVersion: "1.0.0-nightly.100", fromBuild: "100",
                                          notes: notes, appcast: nil)
        let card = try #require(UpdateFeedPosting.card(for: highlights, at: at))
        #expect(card.subject == .app)
        #expect(card.from == "1.0.0-nightly.100")
        #expect(card.to == "1.0.0-nightly.200")
        #expect(card.changes == (highlights.items + (highlights.rest ?? [])).map(\.title))
        #expect(!card.changes.isEmpty)
        // Notes still loading: no card yet (the observation waits for them).
        let loading = UpdateHighlights(version: "1.0.0-nightly.200", build: "200", fromVersion: "1.0.0-nightly.100", fromBuild: "100",
                                       notes: nil, appcast: nil)
        #expect(UpdateFeedPosting.card(for: loading, at: at) == nil)
        // No update (a first install's span runs from this version to itself): no card.
        let same = UpdateHighlights(version: "1.0.0-nightly.200", build: "200", fromVersion: "1.0.0-nightly.200", fromBuild: "200",
                                    notes: notes, appcast: nil)
        #expect(UpdateFeedPosting.card(for: same, at: at) == nil)
        // A record saved before `rest` existed still counts what it left out.
        var old = highlights
        old.rest = nil
        let oldCard = try #require(UpdateFeedPosting.card(for: old, at: at))
        #expect(oldCard.unlisted == highlights.moreCount)
    }

    @Test func eachVersionPostsOnceAndWaitsForItsNotes() throws {
        let notes = ReleaseNotes.debugFake(version: "1.0.0-nightly.200", changes: 3)
        let updated = UpdateHighlights(version: "1.0.0-nightly.200", build: "200", fromVersion: "1.0.0-nightly.100", fromBuild: "100",
                                       notes: notes, appcast: nil)
        let loading = UpdateHighlights(version: "1.0.0-nightly.200", build: "200", fromVersion: "1.0.0-nightly.100", fromBuild: "100",
                                       notes: nil, appcast: nil)
        guard case let .post(card) = UpdateFeedPosting.step(updated, posted: "1.0.0-nightly.100", at: at) else {
            Issue.record("a new version posted no card")
            return
        }
        #expect(card.to == "1.0.0-nightly.200")
        #expect(UpdateFeedPosting.step(updated, posted: "1.0.0-nightly.200", at: at) == .done, "a version posted its card twice")
        #expect(UpdateFeedPosting.step(loading, posted: nil, at: at) == .wait, "the card posted before its notes loaded")
        #expect(UpdateFeedPosting.step(nil, posted: nil, at: at) == .wait)
    }
}
