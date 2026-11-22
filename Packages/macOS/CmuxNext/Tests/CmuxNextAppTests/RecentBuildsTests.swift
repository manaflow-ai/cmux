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
