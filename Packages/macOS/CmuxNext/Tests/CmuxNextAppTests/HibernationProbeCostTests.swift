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

        // The freeze probe answers first (an idle page), and its end runs before the hibernation
        // probe answers.
        gate.answer(0)
        for _ in 0..<4 { await Task.yield() }
        #expect(!recorder.calls.contains(true), "the page froze while its hibernation probe ran")
        gate.answer(1)
        try await rig.until("the page hibernates") { rig.services.cache.phase(of: key) == .hibernated }
        #expect(!recorder.calls.contains(true), "the page froze while its hibernation probe ran")
    }

    /// The picture a page hibernates with comes from the engine's cheap full-size capture
    /// (`thumbnail()`: a fast JPEG for Chromium), not the lossless `snapshot()`: a Chromium PNG is
    /// encoded on the browser's UI thread, the app's main thread (80-140 ms a page), and parsed
    /// there from megabytes of base64, for a picture the store re-encodes as a JPEG anyway.
    @Test func theHibernationPictureIsTheEnginesCheapCapture() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache)
        defer { hibernation.stop() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let picture = await hibernation.capture(tab)
        #expect(picture != nil, "no picture of the page")
        #expect(tab.thumbnailCount == 1, "hibernation took the engine's lossless snapshot, not its cheap capture")
        withExtendedLifetime(services) {}
    }
}
