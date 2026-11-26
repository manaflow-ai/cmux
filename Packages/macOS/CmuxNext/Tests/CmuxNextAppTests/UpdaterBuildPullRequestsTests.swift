import CmuxNextTestSupport
@testable import CmuxNextUpdater
import Foundation
import Testing

/// The update prompt and About list the PRs a build brings (Leo 2026-11-26: "hm do we display which
/// prs go into which nightly maybe that'd be useful per thing?"): the staged update's span from the
/// feed's index and each build's verified notes, and the running build's own notes.
@MainActor @Suite(.serialized) struct UpdaterBuildPullRequestsTests {
    nonisolated static let installed = "100"

    nonisolated static func notes(_ build: String, _ prs: [Int]) -> ReleaseNotes {
        let items = prs.map { ReleaseNotes.ChangeItem(title: "Change \($0)", author: "ada", pr: $0, area: "Mac app") }
        return ReleaseNotes(version: 1, build: build, shortVersion: "1.0.0-nightly.\(build)", date: "2026-11-26",
                            highlights: [], changes: items.map(\.title), items: items)
    }

    static func updater(staged: String?) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.build-prs", shortVersion: "1.0.0-nightly.100",
                                           build: installed, minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
                                           hasPublicKey: false)
        let defaults = UserDefaults(testSuiteName: "UpdaterBuildPullRequestsTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.stagedBuild = { staged }
        updater.indexLoader = {
            ["300", "200", "150", "100", "90"].map {
                ReleaseNotesIndexEntry(build: $0, shortVersion: "1.0.0-nightly.\($0)", date: "2026-11-26", highlights: 0)
            }
        }
        updater.notesLoader = { build in
            switch build {
            case "300": notes("300", [9])
            case "200": notes("200", [7, 6])
            case "150": notes("150", [6, 5])
            case "100": notes("100", [4])
            default: nil
            }
        }
        return updater
    }

    @Test func theStagedUpdateListsThePullRequestsAfterTheInstalledBuild() async throws {
        let updater = Self.updater(staged: "200")
        await updater.loadStagedPullRequests()?.value
        let list = try #require(updater.stagedPullRequests)
        #expect(list.groups.flatMap(\.items).map(\.pr) == [7, 6, 5])
        #expect(list.groups.first?.items.first?.build == "200")
        updater.stagedNotes = Self.notes("200", [7, 6])
        #expect(updater.stagedHighlights?.pullRequests == list)
    }

    @Test func nothingStagedListsNothing() async {
        let updater = Self.updater(staged: nil)
        #expect(updater.loadStagedPullRequests() == nil)
        #expect(updater.stagedPullRequests == nil)
    }

    @Test func aboutListsTheRunningBuildsOwnPullRequests() async {
        let updater = Self.updater(staged: nil)
        let list = await updater.currentBuildPullRequests()
        #expect(list.groups.flatMap(\.items).map(\.pr) == [4])
    }
}
