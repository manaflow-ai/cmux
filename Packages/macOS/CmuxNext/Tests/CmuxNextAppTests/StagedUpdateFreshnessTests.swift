@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// A staged update is replaced when the feed has a newer build (2026-10-21: NIGHTLY staged
/// build 3955987471201 at 08:28Z; about 25 newer nightlies shipped, nothing re-read the feed
/// while it waited, and at 20:23Z Restart installed the 12-hour-old build, after which the
/// launch check staged the next one and "Update Ready" came straight back). While an update
/// waits, the updater re-reads the feed with the read-only probe; a newer build cancels the
/// staged installer and downloads the newest. The install click reads the feed first when no
/// recent probe answered, and installs the newest.
@MainActor @Suite(.serialized) struct StagedUpdateFreshnessTests {
    struct StaticFeed: AppcastFetching {
        let builds: [String]
        func fetch(_ url: URL) async throws -> Data {
            let items = builds.map { "<item><title>\($0)</title><sparkle:version>\($0)</sparkle:version></item>" }.joined()
            return Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>\(items)</channel></rss>
            """.utf8)
        }
    }

    struct FailingFeed: AppcastFetching {
        func fetch(_ url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    /// What the stubbed Sparkle seams saw.
    @MainActor final class Calls {
        var staged: String?
        var cancels = 0
        var installs = 0
        var rechecks: [Bool] = []
    }

    /// The running app is build 100; `staged` is the staged build.
    static func updater(feed: any AppcastFetching, staged: String?, calls: Calls) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.staged-freshness", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(suiteName: "StagedUpdateFreshnessTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     prober: UpdateProber(fetcher: feed, architecture: .arm64), defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        calls.staged = staged
        updater.stagedBuild = { calls.staged }
        updater.cancelStaged = {
            calls.cancels += 1
            calls.staged = nil
            return true
        }
        updater.installStaged = { calls.installs += 1 }
        updater.recheck = { [weak updater] userAsked in
            calls.rechecks.append(userAsked)
            // Sparkle's check queues behind the ending session: the person's shows as checking.
            if userAsked { updater?.debugIndicatorPhase = .checking }
        }
        updater.start()
        if let staged { updater.debugIndicatorPhase = .ready(version: "1.0.\(Int(staged)! - 100)") }
        return updater
    }

    @Test func aNewerBuildInTheFeedReplacesTheStagedOne() async {
        let calls = Calls()
        let updater = Self.updater(feed: StaticFeed(builds: ["100", "101", "102"]), staged: "101", calls: calls)
        await updater.recheckStagedUpdate().value
        #expect(calls.cancels == 1, "the staged 101 stayed while the feed offers 102")
        #expect(calls.rechecks == [false], "the newest build was not downloaded in the background")
        #expect(calls.installs == 0)
    }

    @Test(arguments: [["100", "101"], ["100"], ["99", "100", "101"]])
    func aFeedWithNothingNewerKeepsTheStagedBuild(builds: [String]) async {
        let calls = Calls()
        let updater = Self.updater(feed: StaticFeed(builds: builds), staged: "101", calls: calls)
        await updater.recheckStagedUpdate().value
        #expect(calls.cancels == 0, "the staged build was cancelled though the feed has nothing newer (\(builds))")
        #expect(calls.rechecks.isEmpty)
    }

    @Test func theInstallClickInstallsTheNewestBuild() async {
        let calls = Calls()
        let updater = Self.updater(feed: StaticFeed(builds: ["101", "102"]), staged: "101", calls: calls)
        updater.installClicked()
        await updater.installDecision?.value
        #expect(calls.installs == 0, "Restart installed the stale staged build")
        #expect(calls.cancels == 1)
        #expect(calls.rechecks == [true], "the newest build's download is not the person's check")
        #expect(updater.flow.installRequested, "the newest build will not install once it is staged")

        // The newest downloads and stages: it installs at once, with no second click.
        updater.debugIndicatorPhase = .downloading(UpdateTransfer(stage: .downloading, fraction: 0.5))
        #expect(updater.card == .downloading(UpdateTransfer(stage: .downloading, fraction: 0.5)), "the card does not show the download")
        calls.staged = "102"
        updater.debugIndicatorPhase = .ready(version: "1.0.2")
        await updater.installDecision?.value
        #expect(calls.installs == 1, "the newest staged build did not install")
        #expect(calls.cancels == 1)
    }

    @Test func theInstallClickInstallsTheStagedBuildWhenItIsTheNewest() async {
        let calls = Calls()
        let updater = Self.updater(feed: StaticFeed(builds: ["101"]), staged: "101", calls: calls)
        updater.installClicked()
        await updater.installDecision?.value
        #expect(calls.installs == 1)
        #expect(calls.cancels == 0)
    }

    @Test func theInstallClickInstallsTheStagedBuildWhenTheFeedFails() async {
        let calls = Calls()
        let updater = Self.updater(feed: FailingFeed(), staged: "101", calls: calls)
        updater.installClicked()
        await updater.installDecision?.value
        #expect(calls.installs == 1, "a feed that did not answer blocked the install")
        #expect(calls.cancels == 0)
    }
}
