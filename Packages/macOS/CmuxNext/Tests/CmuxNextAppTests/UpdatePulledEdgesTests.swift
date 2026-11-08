@testable import CmuxNextUpdater
import Foundation
import Testing

/// The edges of "a pulled build is never offered, kept or installed" (``UpdaterService/followPulled()``)
/// and "one click ends on the newest build" (``StagedUpdateRefresh/beforeInstall(updater:install:)``):
/// a slow pulled list, an installer this app cannot cancel, and a found build that waits on its ask.
@MainActor @Suite(.serialized) struct UpdatePulledEdgesTests {
    typealias Click = UpdateClickInstallsNewestTests

    /// A pulled-list read that waits until ``open()``, then answers with `pulled`.
    final class HeldList: @unchecked Sendable {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let data: Data?
        init(pulled: [String]? = nil) {
            data = pulled.map { try! JSONSerialization.data(withJSONObject: $0.map { ["build": $0, "reason": "crashed at launch"] }) }
        }
        func fetch() async -> Data? {
            for await _ in stream { break }
            return data
        }
        func open() { continuation.finish() }
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// The appcast answers at once with newer build 500, and the pulled list takes past the click's
    /// deadline: the click still gives way to 500 instead of installing stale staged build 300.
    @Test func aSlowPulledListDoesNotLoseANewerBuild() async throws {
        let (h, installs) = Click.make(newer: true)
        let list = HeldList()
        defer { list.open() }
        h.updater.pulledWatch.fetch = { _ in await list.fetch() }
        h.updater.installClicked()
        try #require(await eventually { h.feed.fetches == 1 && h.updater.lastProbe != nil }, "the click never read the feed")
        for _ in 0..<40 where installs.count == 0 && h.sparkle.cancels == 0 {
            try await Task.sleep(for: .milliseconds(20))
            h.clock.advance(by: .seconds(1))
        }
        #expect(installs.count == 0, "the slow pulled list made the click install stale build 300")
        #expect(h.sparkle.cancels == 1, "staged build 300 did not give way to 500")
    }

    /// The appcast answers at once with nothing newer, and the pulled list (which lists staged build
    /// 300) takes past the click's deadline: the click waits for the list and never installs 300.
    @Test func aSlowPulledListStillKeepsAPulledStagedBuildFromInstalling() async throws {
        let (h, installs) = Click.make(newer: false)
        let list = HeldList(pulled: ["300"])
        defer { list.open() }
        h.updater.pulledWatch.fetch = { _ in await list.fetch() }
        h.updater.installClicked()
        try #require(await eventually { h.feed.fetches == 1 && h.updater.lastProbe != nil }, "the click never read the feed")
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            h.clock.advance(by: .seconds(1))
        }
        #expect(installs.count == 0, "the deadline installed staged build 300 before the pulled list answered")
        list.open()
        #expect(await eventually { h.sparkle.cancels == 1 }, "pulled build 300 was kept after the list answered")
        #expect(installs.count == 0, "the click installed pulled build 300")
    }

    /// Sparkle stages pulled build 400 while the click waits for the pulled list: the click judges
    /// 400, not the 300 it began with, and never installs it.
    @Test func aPulledBuildStagedWhileTheClickWaitsIsNotInstalled() async throws {
        let (h, installs) = Click.make(newer: false)
        let list = HeldList(pulled: ["400"])
        defer { list.open() }
        h.updater.pulledWatch.fetch = { _ in await list.fetch() }
        h.updater.installClicked()
        try #require(await eventually { h.feed.fetches == 1 && h.updater.lastProbe != nil }, "the click never read the feed")
        h.sparkle.staged = "400"
        list.open()
        #expect(await eventually { h.sparkle.cancels == 1 }, "pulled build 400 was kept")
        #expect(installs.count == 0, "the click installed pulled build 400")
    }

    /// Newer build 500 is on the appcast but no installer this app holds can be cancelled, and the
    /// pulled list (listing staged 300) is slow: the click waits for the list instead of installing 300.
    @Test func aNewerBuildWithNoCancellableInstallerStillWaitsForThePulledList() async throws {
        let (h, installs) = Click.make(newer: true)
        var sheets = 0
        h.updater.presentUpdateUI = { sheets += 1 }
        h.updater.stagedRefresh.cancellable = { false }
        h.updater.cancelStaged = { false }
        let list = HeldList(pulled: ["300"])
        defer { list.open() }
        h.updater.pulledWatch.fetch = { _ in await list.fetch() }
        h.updater.installClicked()
        try #require(await eventually { h.feed.fetches == 1 && h.updater.lastProbe != nil }, "the click never read the feed")
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            h.clock.advance(by: .seconds(1))
        }
        #expect(installs.count == 0, "the deadline installed staged build 300 before the pulled list answered")
        list.open()
        #expect(await eventually { sheets == 1 }, "the click ended in silence")
        #expect(installs.count == 0, "the click installed pulled build 300")
    }

    /// The list says running build 100 was pulled while a check runs: once that check ends with
    /// nothing, the newest good build is still fetched.
    @Test func aPulledRunningBuildReadDuringACheckIsNotMissed() async throws {
        let h = UpdateStagedYieldsToNewerTests.make(ring: "nightly", replaceable: false, pulled: ["100"])
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .hidden
        h.updater.debugIndicatorPhase = .checking
        await h.updater.pulledWatch.refresh().value
        #expect(h.sparkle.backgroundChecks == 0)
        h.updater.debugIndicatorPhase = .hidden
        #expect(h.sparkle.backgroundChecks == 1, "the pulled running build was missed until the next update cycle")
        #expect(h.updater.newestFetch == .runningPulled)
    }

    /// A legacy feed reads two lists: both are read at once, so the click waits one request's time, not two.
    @Test func theLegacyFeedsListsAreReadAtOnce() async {
        let legacy = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
        let started = Started()
        let watch = PulledBuildWatch(build: "300", feedURL: { legacy }, fetch: { _ in
            await started.add()
            try? await Task.sleep(for: .milliseconds(400))
            return nil
        })
        let clock = ContinuousClock(), begin = clock.now
        await watch.refresh().value
        #expect(await started.count == 2)
        #expect(clock.now - begin < .milliseconds(750), "the two lists were read one after the other")
    }

    actor Started {
        var count = 0
        func add() { count += 1 }
    }

    /// A staged build known pulled that no installer this app holds can cancel: no card or footer
    /// pill offers it, and a quit does not claim to have cancelled an installer it could not cancel.
    @Test func aPulledStagedBuildNoOneCanCancelIsNotOffered() async throws {
        let (h, installs) = Click.make(newer: false, pulled: ["300"])
        h.updater.stagedRefresh.cancellable = { false }
        h.updater.cancelStaged = { false }
        await h.updater.pulledWatch.refresh().value
        try #require(h.updater.pulledWatch.isPulled("300"))
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
        #expect(h.updater.card == nil, "pulled build 300 shows as Update Ready")
        #expect(h.updater.footerPill == nil, "pulled build 300 shows as Restart to Update")
        #expect(h.updater.readyCard == nil, "pulled build 300 shows as Update Ready")
        h.updater.checkForUpdates()
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
        #expect(h.updater.readyCard == nil, "a check the person asked for offers pulled build 300")
        h.updater.preferences.installOnQuit = true
        #expect(h.updater.prepareForQuit() == .proceed, "a quit reports an installer it could not cancel as cancelled")
        #expect(installs.count == 0)
    }

    /// A staged build known pulled whose installer this app holds: a quit with install on quit on
    /// cancels it instead of installing it.
    @Test func aQuitCancelsAPulledStagedBuildItsInstallerHolds() async throws {
        let (h, installs) = Click.make(newer: false, pulled: ["300"])
        // Held while Sparkle's silent cycle resumed; by the quit this app holds the installer.
        h.updater.cancelStaged = { false }
        await h.updater.pulledWatch.refresh().value
        try #require(h.updater.pulledWatch.isPulled("300"))
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
        var cancels = 0
        h.updater.cancelStaged = { cancels += 1; return true }
        h.updater.preferences.installOnQuit = true
        #expect(h.updater.prepareForQuit() == .cancelPendingInstall, "a quit installs pulled build 300")
        #expect(cancels == 1, "the quit did not cancel pulled build 300's installer")
        #expect(installs.count == 0)
    }

    /// No installer this app can cancel (Sparkle's own silent driver), and the pulled list not read
    /// yet: the click reads it first, and a pulled staged build is still never installed; the update
    /// sheet opens instead.
    @Test func aPulledBuildWithNoCancellableInstallerIsNotInstalled() async throws {
        let (h, installs) = Click.make(newer: false, pulled: ["300"])
        var sheets = 0
        h.updater.presentUpdateUI = { sheets += 1 }
        h.updater.stagedRefresh.cancellable = { false }
        h.updater.cancelStaged = { false }
        h.updater.installClicked()
        #expect(await eventually { sheets == 1 }, "the click ended in silence")
        #expect(installs.count == 0, "the click installed pulled build 300")
    }

    /// With downloads asking, a cached appcast offers known-pulled build 500: it is not shown as
    /// "Update Available" and never downloads.
    @Test func aPulledFoundBuildIsNotOffered() async throws {
        let (h, installs) = Click.make(newer: false, downloadsAsk: true, pulled: ["500"])
        await h.updater.pulledWatch.refresh().value
        try #require(h.updater.pulledWatch.isPulled("500"))
        var dismissed = 0
        h.updater.availableBuild = { "500" }
        h.updater.dismissAvailable = { dismissed += 1 }
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .hidden
        h.updater.debugIndicatorPhase = .checking
        h.updater.debugIndicatorPhase = .available(version: "5.0.0")
        #expect(dismissed == 1, "pulled build 500 is offered")
        #expect(installs.downloads == 0, "pulled build 500 downloaded")
    }

    /// A carried fetch for the newest build (here a pulled running build's) that finds a known-pulled
    /// build ends when that prompt ends: "Getting the Newest Build…" never stays up.
    @Test func aPulledFoundBuildEndsTheNewestFetch() async throws {
        let (h, installs) = Click.make(newer: false, downloadsAsk: true, pulled: ["500"])
        await h.updater.pulledWatch.refresh().value
        h.updater.availableBuild = { "500" }
        h.sparkle.staged = nil
        h.updater.newestFetch = .runningPulled
        h.updater.debugIndicatorPhase = .hidden
        h.updater.debugIndicatorPhase = .checking
        h.updater.debugIndicatorPhase = .available(version: "5.0.0")
        h.updater.debugIndicatorPhase = .hidden
        #expect(installs.downloads == 0, "pulled build 500 downloaded")
        #expect(h.updater.newestFetch == nil, "the fetch for the newest build never ended")
        #expect(h.updater.newestCard == nil)
    }
}
