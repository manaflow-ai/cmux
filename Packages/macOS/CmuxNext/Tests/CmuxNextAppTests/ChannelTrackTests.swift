@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// The channels view's tracks (Settings > Updates): one per ring, the Nightly track from the
/// feed's build index with each build's verdict or pull, "You are here" on the running build,
/// and links that only ever point at GitHub commits.
struct ChannelTrackTests {
    private static let index = [
        ReleaseNotesIndexEntry(build: "300", shortVersion: "1.0.0-nightly.300", date: "2026-10-21", highlights: 2, head: "cccccccc"),
        ReleaseNotesIndexEntry(build: "200", shortVersion: "1.0.0-nightly.200", date: "2026-10-20", highlights: 0, head: "bbbbbbbb"),
        ReleaseNotesIndexEntry(build: "100", shortVersion: "1.0.0-nightly.100", date: "2026-10-19", highlights: 1, head: nil),
    ]

    private static func tracks(installed: String = "200", followed: UpdateRing = .nightly, limit: Int = 10) -> [ChannelTrack] {
        ChannelTrack.tracks(index: index, verdicts: ["300": "fail", "200": "pass", "100": "skipped"],
                            pulled: [PulledBuild(build: "300", reason: "crashes on launch")],
                            installedBuild: installed, keptBuilds: ["100"], followed: followed, limit: limit)
    }

    @Test func oneTrackPerRingSlowestFirstAndOnlyTheFollowedOneMarked() {
        let tracks = Self.tracks(followed: .canary)
        #expect(tracks.map(\.ring) == [.stable, .nightly, .canary, .dev])
        #expect(tracks.filter(\.isFollowed).map(\.ring) == [.canary])
        // Dev takes every published build; Stable and Canary have none until CI publishes them.
        #expect(tracks.map(\.builds.count) == [0, 3, 0, 3])
    }

    @Test func eachBuildCarriesItsVerdictPullAndKeptCopy() throws {
        let nightly = try #require(Self.tracks().first { $0.ring == .nightly })
        #expect(nightly.builds.map(\.health) == [.pulled, .promoted, .pending])
        #expect(nightly.builds[0].pulledReason == "crashes on launch")
        #expect(nightly.builds.map(\.isKept) == [false, false, true])
        #expect(nightly.installed?.build == "200")
        #expect(nightly.releaseURL?.absoluteString == "https://github.com/manaflow-ai/cmux/releases/tag/nightly-next")
    }

    @Test func theRunningBuildOffTheRecentListMarksNothing() {
        #expect(Self.tracks(installed: "50").allSatisfy { $0.installed == nil })
        #expect(Self.tracks(limit: 2).first { $0.ring == .nightly }?.builds.map(\.build) == ["300", "200"])
    }

    @Test func compareGoesFromTheInstalledBuildsCommit() throws {
        let nightly = try #require(Self.tracks().first { $0.ring == .nightly })
        let installed = nightly.installed
        #expect(nightly.builds[0].compareURL(from: installed)?.absoluteString
            == "https://github.com/manaflow-ai/cmux/compare/bbbbbbbb...cccccccc")
        #expect(nightly.builds[1].compareURL(from: installed) == nil)
        // No commit in the index: no compare and no commit link.
        #expect(nightly.builds[2].compareURL(from: installed) == nil)
        #expect(nightly.builds[2].commitURL == nil)
        #expect(nightly.builds[0].commitURL?.absoluteString == "https://github.com/manaflow-ai/cmux/commit/cccccccc")
    }

    @Test func aFeedValueThatIsNotACommitNeverBecomesALink() {
        let odd = ChannelBuild(build: "1", shortVersion: "1", date: "", commit: "../../evil")
        #expect(odd.commitURL == nil)
        #expect(odd.compareURL(from: ChannelBuild(build: "0", shortVersion: "0", date: "", commit: "abcdef12")) == nil)
    }

    @Test func verdictsAreReadPerBuildAndUnsafeNamesAreSkipped() async {
        let folder = URL(string: "https://files-next.cmux.com/nightly-next/next/")!
        let verdicts = await UpdaterService.verdicts(for: ["300", "../x"], in: folder) { url in
            url.lastPathComponent == "300.json" ? Data(#"{"schema":1,"build":"300","verdict":"pass"}"#.utf8) : nil
        }
        #expect(verdicts == ["300": "pass"])
    }

    @Test(arguments: [
        ("https://files-next.cmux.com/nightly-next/next/notes/", "https://files-next.cmux.com/nightly-next/next/"),
        // A DEV build's notes and the legacy NIGHTLY feed sit one folder up; verdicts and pulls do not.
        ("https://files-next.cmux.com/nightly-next/notes/", "https://files-next.cmux.com/nightly-next/next/"),
        ("https://127.0.0.1:8080/feed/notes/", "https://127.0.0.1:8080/feed/"),
    ])
    func verdictsAndPullsAreReadBesideTheCmuxNextAppcast(notesBase: String, folder: String) throws {
        let base = try #require(URL(string: notesBase))
        #expect(UpdaterService.channelFolder(notesBase: base).absoluteString == folder)
    }

    @Test func theIndexDecodesWithAndWithoutItsCommit() throws {
        let json = #"[{"build":"3","date":"d","head":"abc1234","highlights":1,"shortVersion":"s"},{"build":"2","date":"d","highlights":0,"shortVersion":"s"}]"#
        let entries = try JSONDecoder().decode([ReleaseNotesIndexEntry].self, from: Data(json.utf8))
        #expect(entries.map(\.head) == ["abc1234", nil])
    }
}
