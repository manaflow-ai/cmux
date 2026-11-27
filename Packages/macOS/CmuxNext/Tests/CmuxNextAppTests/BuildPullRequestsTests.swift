import CmuxNextUpdater
import Foundation
import Testing

/// "What's in this build" (Leo 2026-11-26: "hm do we display which prs go into which nightly maybe
/// that'd be useful per thing?"): the pull requests merged after the build this Mac runs, up to the
/// offered one, grouped by area. Each build's notes list the commits since the previous build that
/// published notes, so the span is the union of the notes of every build after the installed one.
struct BuildPullRequestsTests {
    private static func entry(_ build: String) -> ReleaseNotesIndexEntry {
        ReleaseNotesIndexEntry(build: build, shortVersion: "1.0.0-nightly.\(build)", date: "2026-11-26", highlights: 0)
    }

    private static func notes(_ build: String, _ items: [ReleaseNotes.ChangeItem]) -> ReleaseNotes {
        ReleaseNotes(version: 1, build: build, shortVersion: "1.0.0-nightly.\(build)", date: "2026-11-26", highlights: [],
                     changes: items.map(\.title), items: items)
    }

    @Test func theSpanIsEveryIndexedBuildAfterTheInstalledOneThroughTheOffered() {
        // Newest first, as notes/index.json lists them; builds compare as numbers, not text.
        let index = ["4572038238101", "4563102208501", "999", "4557519416001", "4557245517201"].map(Self.entry)
        #expect(BuildPullRequests.builds(in: index, after: "4557245517201", through: "4563102208501")
            == ["4563102208501", "4557519416001"])
        // The offered build not yet in the index still bounds the span; newer builds stay out.
        #expect(BuildPullRequests.builds(in: index, after: "4557519416001", through: "4600000000000")
            == ["4572038238101", "4563102208501"])
        // Nothing newer: nothing listed.
        #expect(BuildPullRequests.builds(in: index, after: "4572038238101", through: "4572038238101").isEmpty)
        // Unsafe names never become a notes path.
        #expect(BuildPullRequests.builds(in: [Self.entry("../x")], after: "1", through: "9").isEmpty)
    }

    @Test func pullRequestsAreDedupedNewestFirstAndGroupedByArea() throws {
        let newer = Self.notes("20", [
            .init(title: "Sidebar rows keep their order", author: "ada", pr: 30, area: "Mac app"),
            .init(title: "Phone reconnects", author: "bo", pr: 29, area: "iOS"),
            .init(title: "ci: faster lint", author: "cy", pr: 28, isInternal: true, area: "CI and tooling"),
            .init(title: "Direct push without a PR"),
        ])
        let older = Self.notes("10", [
            .init(title: "Sidebar rows keep their order (again)", author: "ada", pr: 30, area: "Mac app"),
            .init(title: "No area yet", author: "dee", pr: 27),
            .init(title: "Tabs restore", author: "eve", pr: 26, area: "Mac app"),
        ])
        // Given in any order: the newest build's items come first.
        let list = BuildPullRequests(notes: [older, newer])
        #expect(list.groups.map(\.area) == ["Mac app", "iOS", nil])
        let mac = try #require(list.groups.first)
        #expect(mac.items.map(\.pr) == [30, 26])
        #expect(mac.items[0].title == "Sidebar rows keep their order")
        #expect(mac.items[0].author == "ada")
        #expect(mac.items[0].build == "20")
        #expect(mac.items[0].url == URL(string: "https://github.com/manaflow-ai/cmux/pull/30"))
        #expect(list.groups.last?.items.map(\.pr) == [27])
        // Internal (CI or tooling only) changes are counted, not listed; a commit without a PR is neither.
        #expect(list.internalCount == 1)
        #expect(list.count == 4)
        #expect(!list.isEmpty)
        #expect(BuildPullRequests(notes: []).isEmpty)
    }

    @Test func aBlankAreaReadsAsOther() {
        let list = BuildPullRequests(notes: [Self.notes("5", [.init(title: "A", pr: 1, area: "  ")])])
        #expect(list.groups.map(\.area) == [nil])
    }

    @Test func theAreaFieldDecodesAsOptional() throws {
        let json = #"""
        {"version":1,"build":"10","shortVersion":"1.0.0-nightly.10","date":"2026-10-26","highlights":[],"changes":["a (#3)","b (#2)"],
         "items":[{"title":"a","author":"Ada","pr":3,"area":"iOS"},{"title":"b","pr":2}]}
        """#
        let notes = try JSONDecoder().decode(ReleaseNotes.self, from: Data(json.utf8))
        #expect(notes.changeItems.map(\.area) == ["iOS", nil])
    }
}
