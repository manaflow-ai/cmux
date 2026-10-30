@testable import CmuxNextUpdater
import Foundation
import Testing

/// The edges of "a pulled build is never offered, kept or installed" (``UpdaterService/followPulled()``)
/// and "one click ends on the newest build" (``StagedUpdateRefresh/beforeInstall(updater:install:)``):
/// a slow pulled list, an installer this app cannot cancel, and a found build that waits on its ask.
@MainActor @Suite(.serialized) struct UpdatePulledEdgesTests {
    typealias Click = UpdateClickInstallsNewestTests

    /// A pulled-list read that waits until ``open()``.
    final class HeldList: @unchecked Sendable {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        func fetch() async -> Data? {
            for await _ in stream { break }
            return nil
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
        // Build 7 (some old pulled build) shows the launch read of the list is done.
        let (h, installs) = Click.make(newer: true, pulled: ["7"])
        let list = HeldList()
        defer { list.open() }
        try #require(await eventually { h.updater.pulledWatch.isPulled("7") })
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

    /// No installer this app can cancel (Sparkle's own silent driver): a pulled staged build is
    /// still never installed by the click; the update sheet opens instead.
    @Test func aPulledBuildWithNoCancellableInstallerIsNotInstalled() async throws {
        let (h, installs) = Click.make(newer: false, pulled: ["300"])
        try #require(await eventually { h.updater.pulledWatch.isPulled("300") })
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
        try #require(await eventually { h.updater.pulledWatch.isPulled("500") })
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
}
