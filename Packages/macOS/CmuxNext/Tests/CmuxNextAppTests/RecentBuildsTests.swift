@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// `updates.builds` (`cmux nightly list|install`, Install an Earlier Nightly…): the nightly track
/// with each build's titles, and Switch offered on every build but the running and pulled ones.
struct RecentBuildsTests {
    private static func builds(switches: Bool) -> [RecentBuild] {
        let index = [
            ReleaseNotesIndexEntry(build: "300", shortVersion: "1.0.0-nightly.300", date: "2026-10-22", highlights: 0, head: "cccccccc"),
            ReleaseNotesIndexEntry(build: "250", shortVersion: "1.0.0-nightly.250", date: "2026-10-21", highlights: 0, head: "dddddddd"),
            ReleaseNotesIndexEntry(build: "200", shortVersion: "1.0.0-nightly.200", date: "2026-10-20", highlights: 0, head: "bbbbbbbb"),
        ]
        let tracks = ChannelTrack.tracks(index: index, verdicts: [:], pulled: [PulledBuild(build: "250", reason: "crashes", pulledAt: "", serve: "200")],
                                         installedBuild: "300", keptBuilds: ["200"], followed: .nightly)
        let nightly = tracks.first { $0.ring == .nightly }?.builds ?? []
        return UpdaterService.recentBuilds(nightly, titles: ["200": ["Faster tabs"]], switches: switches)
    }

    @Test func everyBuildButTheRunningAndPulledOnesIsSwitchable() {
        let builds = Self.builds(switches: true)
        #expect(builds.map(\.build) == ["300", "250", "200"])
        #expect(builds.map(\.switchable) == [false, false, true])
        #expect(builds.map(\.installed) == [true, false, false])
        #expect(builds[1].health == "pulled" && builds[1].pulledReason == "crashes")
        #expect(builds[2].kept && builds[2].titles == ["Faster tabs"] && builds[2].commit == "bbbbbbbb")
    }

    @Test func nothingIsSwitchableOnABuildThatFollowsNoFeed() {
        #expect(Self.builds(switches: false).allSatisfy { !$0.switchable })
    }

    @Test func aLimitNoIntHoldsIsTheDefaultNotATrap() {
        #expect(UpdaterService.recentBuildsLimit(nil) == 10)
        #expect(UpdaterService.recentBuildsLimit(1e308) == 10)
        #expect(UpdaterService.recentBuildsLimit(.nan) == 10)
        #expect(UpdaterService.recentBuildsLimit(-.infinity) == 10)
        #expect(UpdaterService.recentBuildsLimit(0) == 1)
        #expect(UpdaterService.recentBuildsLimit(7.9) == 7)
        #expect(UpdaterService.recentBuildsLimit(500) == 50)
    }
}

/// One source for the list, the install and the updater (2026-11-22: the appcast offered
/// 4495894547301 at 23:16Z, the updater installed it, and `notes/index.json` listed it only at
/// 00:00Z, so `cmux nightly list` showed no installed row and `cmux nightly install` refused it).
/// The appcast decides which builds exist; the notes index only adds commits and titles.
struct RecentBuildsFeedAheadOfNotesTests {
    private static let appcast = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>
    <item><title>4495894547301</title><pubDate>Sat, 21 Nov 2026 15:14:33 -0800</pubDate>
    <sparkle:version>4495894547301</sparkle:version><sparkle:shortVersionString>1.0.0-nightly.4495894547301</sparkle:shortVersionString>
    <sparkle:channel>cmux-next</sparkle:channel>
    <enclosure url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-4495894547301.dmg" length="12" sparkle:edSignature="c2ln"/></item>
    <item><title>4495375783401</title><pubDate>Sat, 21 Nov 2026 14:19:43 -0800</pubDate>
    <sparkle:version>4495375783401</sparkle:version><sparkle:shortVersionString>1.0.0-nightly.4495375783401</sparkle:shortVersionString>
    <sparkle:channel>cmux-next</sparkle:channel>
    <enclosure url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-4495375783401.dmg" length="12" sparkle:edSignature="c2ln"/></item>
    <item><title>4495068035301</title><pubDate>Sat, 21 Nov 2026 13:30:00 -0800</pubDate>
    <sparkle:version>4495068035301</sparkle:version><sparkle:shortVersionString>1.0.0-nightly.4495068035301</sparkle:shortVersionString>
    <sparkle:channel>cmux-next</sparkle:channel>
    <enclosure url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-4495068035301.dmg" length="12" sparkle:edSignature="c2ln"/></item>
    <item><title>canary</title><sparkle:version>4496000000001</sparkle:version><sparkle:channel>cmux-next-canary</sparkle:channel></item>
    </channel></rss>
    """

    /// One build behind the appcast, as published at 23:05Z.
    private static let notes = """
    {"builds":[
    {"build":"4495375783401","date":"2026-11-21","head":"afeb89238dab8549f5e07a08c5861d14fc34affb","highlights":0,"shortVersion":"1.0.0-nightly.4495375783401"},
    {"build":"4495068035301","date":"2026-11-21","head":"d0b731b6e91b2b520942085fafd44a09173543e5","highlights":0,"shortVersion":"1.0.0-nightly.4495068035301"},
    {"build":"4494208705801","date":"2026-11-21","head":"340e97e56edd701ca6fa9a1245be9e05c5660c21","highlights":2,"shortVersion":"1.0.0-nightly.4494208705801"}
    ]}
    """

    private static func builds(installed: String = "4495894547301", pulled: [PulledBuild] = [], followed: UpdateRing = .nightly,
                               verdicts: [String: String] = [:], limit: Int = 10) throws -> [RecentBuild] {
        let feed = try AppcastParser.parse(Data(appcast.utf8))
        struct Index: Decodable { var builds: [ReleaseNotesIndexEntry] }
        let index = try JSONDecoder().decode(Index.self, from: Data(notes.utf8)).builds
        let tracks = ChannelTrack.tracks(index: index, verdicts: verdicts, pulled: pulled, installedBuild: installed,
                                         keptBuilds: [], followed: followed, limit: limit, feedItems: feed)
        let nightly = tracks.first { $0.ring == .nightly }?.builds ?? []
        return UpdaterService.recentBuilds(nightly, titles: ["4495375783401": ["Faster tabs"]], switches: true)
    }

    @Test func theBuildTheAppcastOffersBeforeItsNotesIsListedNewestFirstAndInstalled() throws {
        let builds = try Self.builds()
        #expect(builds.map(\.build) == ["4495894547301", "4495375783401", "4495068035301", "4494208705801"])
        let ahead = try #require(builds.first)
        #expect(ahead.installed && !ahead.switchable)
        #expect(ahead.version == "1.0.0-nightly.4495894547301" && ahead.date == "2026-11-21")
        #expect(ahead.commit == nil && ahead.titles.isEmpty && ahead.health == "pending")
        // Builds in both keep what the notes say.
        #expect(builds[1].commit == "afeb89238dab8549f5e07a08c5861d14fc34affb" && builds[1].titles == ["Faster tabs"])
        #expect(builds.filter(\.installed).count == 1)
    }

    @Test func fromAnOlderBuildTheBuildAheadOfItsNotesIsSwitchable() throws {
        let builds = try Self.builds(installed: "4495375783401", verdicts: ["4495894547301": "pass"])
        let ahead = try #require(builds.first { $0.build == "4495894547301" })
        #expect(ahead.switchable && !ahead.installed && ahead.health == "promoted")
        #expect(builds.first { $0.build == "4495375783401" }?.installed == true)
    }

    @Test func aPulledBuildIsRefusedWhetherItsNotesAreOutOrNot() throws {
        let builds = try Self.builds(installed: "4494208705801",
                                     pulled: [PulledBuild(build: "4495894547301", reason: "crashes"),
                                              PulledBuild(build: "4495375783401", reason: "hangs")])
        let ahead = try #require(builds.first { $0.build == "4495894547301" })
        #expect(!ahead.switchable && ahead.health == "pulled" && ahead.pulledReason == "crashes")
        let inNotes = try #require(builds.first { $0.build == "4495375783401" })
        #expect(!inNotes.switchable && inNotes.health == "pulled" && inNotes.pulledReason == "hangs")
        #expect(builds.first { $0.build == "4495068035301" }?.switchable == true)
    }

    @Test func aFasterRingsBuildIsListedOnlyForAMacThatFollowsIt() throws {
        #expect(try Self.builds().contains { $0.build == "4496000000001" } == false)
        let canary = try Self.builds(installed: "4496000000001", followed: .canary)
        #expect(canary.first?.build == "4496000000001" && canary.first?.installed == true)
    }

    @Test func theLimitCountsTheMergedList() throws {
        #expect(try Self.builds(limit: 2).map(\.build) == ["4495894547301", "4495375783401"])
    }
}
