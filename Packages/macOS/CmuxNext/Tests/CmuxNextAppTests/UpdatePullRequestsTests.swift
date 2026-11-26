import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
@testable import CmuxNextUpdater
import Testing

/// "What's in this build" (Leo 2026-11-26: "hm do we display which prs go into which nightly maybe
/// that'd be useful per thing?"): the update prompt and Settings > Updates list the PRs merged since
/// the installed build, across every skipped nightly, grouped by area, each linked to its PR.
@MainActor @Suite(.serialized) struct UpdatePullRequestsTests {
    nonisolated static func notes(_ build: String, _ items: [ReleaseNotes.ChangeItem]) -> ReleaseNotes {
        ReleaseNotes(version: 1, build: build, shortVersion: "1.0.0-nightly.\(build)", date: "2026-11-26", highlights: [],
                     changes: [], items: items)
    }

    nonisolated static func entry(_ build: String) -> ReleaseNotesIndexEntry {
        ReleaseNotesIndexEntry(build: build, shortVersion: "1.0.0-nightly.\(build)", date: "2026-11-26", highlights: 0)
    }

    @Test func theSpanIsEveryBuildAfterTheInstalledOneUpToTheOffered() {
        let index = ["1000", "999", "998", "997", "996"].map(Self.entry)
        #expect(UpdatePullRequests.span(index: index, installed: "997", offered: "999") == ["999", "998"])
        // The offered build not yet in the index still counts; a newer one in it does not.
        #expect(UpdatePullRequests.span(index: index, installed: "998", offered: "1001") == ["1001", "1000", "999"])
        #expect(UpdatePullRequests.span(index: [], installed: "998", offered: "999") == ["999"])
        #expect(UpdatePullRequests.span(index: index, installed: "dev", offered: "999") == ["999"])
        let long = (1...200).map { Self.entry(String($0)) }
        #expect(UpdatePullRequests.span(index: long, installed: "1", offered: "200").count == UpdatePullRequests.spanLimit)
    }

    @Test func prsAreGroupedByAreaOncePerPROtherLast() {
        let newer = Self.notes("999", [
            .init(title: "Pinned tabs keep their order", author: "lawrence", pr: 12, area: "Sidebar"),
            .init(title: "Find bar remembers its query", author: "leo", pr: 13, area: "terminal"),
            .init(title: "CI cache key", pr: 14, isInternal: true, area: "terminal"),
            .init(title: "A commit with no PR"),
        ])
        let older = Self.notes("998", [
            .init(title: "Pinned tabs keep their order", pr: 12, area: "sidebar"),
            .init(title: "Sidebar rows fade on hover", author: "austin", pr: 11, area: "sidebar"),
            .init(title: "Faster cold start", author: "leo", pr: 10,
                  link: URL(string: "https://github.com/manaflow-ai/cmux/pull/10#files")),
        ])
        let prs = UpdatePullRequests(notes: [older, newer])
        #expect(prs.groups.map(\.area) == ["sidebar", "terminal", "other"])
        #expect(prs.groups[0].items.map(\.pr) == [12, 11], "a PR in two builds listed twice, or out of order")
        #expect(prs.groups[0].items[0].build == "999")
        #expect(prs.groups[1].items.map(\.title) == ["Find bar remembers its query"], "an internal-only change was listed")
        #expect(prs.groups[2].items.map(\.url) == [URL(string: "https://github.com/manaflow-ai/cmux/pull/10#files")])
        #expect(prs.groups[0].items[1].url == URL(string: "https://github.com/manaflow-ai/cmux/pull/11"))
        #expect(prs.count == 4)
        #expect(prs.builds == ["999", "998"])
    }

    /// Today's feed has no `area` or `url`: every PR is filed under Other and links to its pull page.
    @Test func todaysNotesDecodeAndFileUnderOther() throws {
        let json = #"{"version":1,"build":"999","shortVersion":"1.0.0-nightly.999","date":"2026-11-26","highlights":[],"changes":[],"#
            + #""items":[{"title":"Faster cold start","author":"leo","pr":10},{"title":"Area","pr":11,"area":"panes","url":"https://github.com/manaflow-ai/cmux/pull/11"},"#
            + #"{"title":"Bad link","pr":12,"area":"  ","url":"not a url at all"}]}"#
        let notes = try JSONDecoder().decode(ReleaseNotes.self, from: Data(json.utf8))
        let prs = UpdatePullRequests(notes: [notes])
        #expect(prs.groups.map(\.area) == ["panes", "other"])
        #expect(prs.groups[1].items.map(\.url) == [URL(string: "https://github.com/manaflow-ai/cmux/pull/10"),
                                                   URL(string: "https://github.com/manaflow-ai/cmux/pull/12")])
    }

    static func updater() -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-pull-requests", shortVersion: "1.0.0-nightly.997",
                                           build: "997", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(testSuiteName: "UpdatePullRequestsTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.stagedBuild = { "999" }
        let all = ["999": Self.notes("999", [.init(title: "Find bar remembers its query", author: "leo", pr: 13, area: "terminal")]),
                   "998": Self.notes("998", [.init(title: "Sidebar rows fade on hover", author: "austin", pr: 11, area: "sidebar")]),
                   "997": Self.notes("997", [.init(title: "Already installed", pr: 9, area: "sidebar")])]
        updater.notesLoader = { all[$0] }
        updater.indexLoader = { ["1000", "999", "998", "997"].map(Self.entry) }
        updater.start()
        return updater
    }

    /// The staged update's prompt and the Settings card carry every skipped build's PRs.
    @Test func theStagedUpdateListsEverySkippedBuildsPRs() async throws {
        let updater = Self.updater()
        updater.debugIndicatorPhase = .ready(version: "1.0.0-nightly.999")
        updater.syncFlowPhase()
        await updater.stagedNotesTask?.task.value
        let prs = try #require(updater.stagedPullRequests)
        #expect(prs.builds == ["999", "998"])
        #expect(updater.stagedHighlights?.prs == prs)
        let surface = try updater.surfaceJSON(updated: false, background: false)
        #expect(surface["prs"]?["groups"]?.arrayValue?.count == 2)
        let settings = updater.settingsPageJSON
        let groups = try #require(settings["prs"]?["groups"]?.arrayValue)
        #expect(groups.compactMap { $0["area"]?.stringValue } == ["terminal", "sidebar"])
        #expect(groups.first?["items"]?.arrayValue?.first?["url"]?.stringValue == "https://github.com/manaflow-ai/cmux/pull/13")

        updater.debugIndicatorPhase = .hidden
        updater.syncFlowPhase()
        #expect(updater.stagedPullRequests == nil)
        #expect(updater.settingsPageJSON["prs"] == nil)
    }
}
