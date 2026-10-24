import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextSettings
import Foundation
import Testing

/// What hibernating a hidden page costs the app (perf-lead.md row 15, the STRESS run of
/// 2026-10-24 on cmux19: 10 hidden pages past the budget kept as "unanswered", main-thread stalls
/// of 53-379 ms while pages hibernated).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HibernationProbeCostTests {
    /// Probes that answer only when the test says, in the order they asked.
    @MainActor final class Gate {
        private(set) var waiting: [CheckedContinuation<PageProbe, Never>?] = []

        func ask() async -> PageProbe {
            await withCheckedContinuation { waiting.append($0) }
        }

        func answer(_ index: Int, with probe: PageProbe = PageProbe()) {
            waiting[index]?.resume(returning: probe)
            waiting[index] = nil
        }

        func answerAll() {
            for index in waiting.indices { answer(index) }
        }
    }

    /// Engine captures hibernation asked for.
    @MainActor final class Captures {
        private(set) var count = 0

        func take() -> CGImage? {
            count += 1
            return nil
        }
    }

    /// A hidden Chromium page's freeze probe can still be out when its hibernation probe starts
    /// (the freeze comes after 30 s, the budget after 60 s, and a busy page answers late). The
    /// freeze probe's end froze the page while the hibernation probe's scripts waited on it, so the
    /// hibernation probe ran into its deadline, the page counted as unanswered and stayed live past
    /// the budget. Now a page never freezes while its hibernation probe runs, and it hibernates.
    @Test func aFreezeProbeEndingDuringTheHibernationProbeDoesNotFreezeThePage() async throws {
        let rig = try NeighborTabsWakeTests.Rig()
        let gate = Gate()
        defer {
            gate.answerAll()
            rig.close()
        }
        rig.hibernation.probe = { _ in await gate.ask() }
        rig.hibernation.capture = { _ in nil }
        // The freeze is due after 50 ms, the hibernation after 0.5 s: the freeze probe asks first.
        rig.hibernation.apply(BrowserHibernationSetting(mode: .minutes(0.5 / 60), freezeSeconds: 0.05))
        let keys = try await rig.pages(["slow"])
        let key = try #require(keys.first)
        let recorder = try #require(rig.recorders[key])
        try await rig.until("the freeze probe, then the hibernation probe, ask") { gate.waiting.count == 2 }
        #expect(recorder.calls.isEmpty, "the page froze before its freeze probe answered (the test's premise)")

        // The freeze probe answers first (an idle page), then the hibernation probe. A freeze at the
        // freeze probe's end shows in the recorder whenever it ran.
        gate.answer(0)
        gate.answer(1)
        try await rig.until("the page hibernates") { rig.services.cache.phase(of: key) == .hibernated }
        #expect(!recorder.calls.contains(true), "the page froze while its hibernation probe ran")
    }

    /// The picture a page hibernates with is the one the app already took as the page left the
    /// screen (`pageDidLeave`, the leave capture's full-size image), not a second engine capture at
    /// hibernation time: a Chromium capture is encoded on the browser's UI thread, the app's main
    /// thread (20-35 ms a page even as a fast JPEG, a few pages a pass), and a hidden page often
    /// pictures blank.
    @Test func aPageHibernatesWithThePictureItLeftWithAndTakesNoCapture() async throws {
        let rig = try NeighborTabsWakeTests.Rig(freezes: false)
        defer { rig.close() }
        let captures = Captures()
        rig.hibernation.capture = { _ in captures.take() }
        let key = try #require(try await rig.pages(["left"]).first)
        let entry = try #require(rig.services.cache.browsers[key])
        rig.hibernation.apply(BrowserHibernationSetting(mode: .minutes(30), freezeSeconds: nil))
        await rig.hibernation.pageDidLeave(key, tab: entry.tab, image: try Self.picture(width: 1200, height: 800),
                                           version: TabContentCache.pageVersion(entry))

        rig.hibernation.apply(BrowserHibernationSetting(mode: .minutes(0.2 / 60), freezeSeconds: nil))
        try await rig.until("the page hibernates") { rig.services.cache.phase(of: key) == .hibernated }
        #expect(captures.count == 0, "hibernation captured the page again (\(captures.count) captures)")
        #expect(rig.hibernation.snapshotImage(key)?.width == 1200, "the page hibernated without the picture it left with")
    }

    /// A leave picture of an older page version (it navigated or loaded since) is not the page's
    /// picture: hibernation captures the page instead.
    @Test func aLeavePictureOfAnOlderPageVersionIsNotUsed() async throws {
        let rig = try NeighborTabsWakeTests.Rig(freezes: false)
        defer { rig.close() }
        let captures = Captures()
        rig.hibernation.capture = { _ in captures.take() }
        let key = try #require(try await rig.pages(["moved"]).first)
        let entry = try #require(rig.services.cache.browsers[key])
        rig.hibernation.apply(BrowserHibernationSetting(mode: .minutes(30), freezeSeconds: nil))
        await rig.hibernation.pageDidLeave(key, tab: entry.tab, image: try Self.picture(width: 1200, height: 800),
                                           version: TabContentCache.pageVersion(entry) &+ 1)

        rig.hibernation.apply(BrowserHibernationSetting(mode: .minutes(0.2 / 60), freezeSeconds: nil))
        try await rig.until("the page hibernates") { rig.services.cache.phase(of: key) == .hibernated }
        #expect(captures.count == 1, "hibernation used a picture of another page version")
    }

    /// An opaque gray picture of a page.
    private static func picture(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
