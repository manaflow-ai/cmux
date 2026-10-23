import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The made-ahead open panel's warm-up never blocks the main thread on the panel service (2026-10-23).
/// `NSOpenPanel()` waits synchronously on its view service; with no GUI session the service never answers
/// and the warm-up held the main thread about 40 s (aws-m4pro-3: 10 + 10 + 20 s of `HostCallsAuxiliary`
/// waits), a beachball for anyone whose panel service is slow or restarting. The warm-up must ask the
/// service off the main thread, give up at a deadline, stop for the launch after a failure, and leave the
/// click to make its panel on demand. The factory here stands in for `NSOpenPanel()` waiting on a service
/// that never answers, so the test can count the main-thread time it would cost.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct MadeAheadOpenPanelWarmUpTests {
    /// One 60 Hz frame: the most a warm-up may hold the main thread.
    private static let frame = Duration.milliseconds(1000) / 60

    /// A panel service whose answer never comes until the test lets it go.
    private actor SilentService {
        private var waiting: [CheckedContinuation<Bool, Never>] = []
        func ask() async -> Bool { await withCheckedContinuation { waiting.append($0) } }
        func release() {
            waiting.forEach { $0.resume(returning: false) }
            waiting = []
        }
    }

    /// What the stand-in factory cost the main thread.
    @MainActor private final class Factory {
        var calls = 0
        var blocked = Duration.zero
        let wait: TimeInterval
        init(wait: TimeInterval) { self.wait = wait }
        func make() -> NSOpenPanel? {
            calls += 1
            let start = ContinuousClock.now
            // Stands in for NSOpenPanel()'s synchronous wait on a service that does not answer.
            Thread.sleep(forTimeInterval: wait)
            blocked += ContinuousClock.now - start
            return nil
        }
    }

    private func world(_ factory: Factory, ready: @escaping @Sendable () async -> Bool) -> MadeAheadOpenPanelWorld {
        MadeAheadOpenPanelWorld(makePanel: { factory.make() }, serviceReady: ready, gate: { .go },
                                firstCheck: .zero, retry: .zero, serviceDeadline: .milliseconds(100))
    }

    private func settle(_ panel: MadeAheadOpenPanel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(panel.stoppedWarming && !panel.isWarming), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aServiceThatNeverAnswersNeverBlocksTheMainThreadAndStopsTheWarmUp() async throws {
        let service = SilentService()
        let factory = Factory(wait: 0.4)
        let panel = MadeAheadOpenPanel(world: world(factory) { await service.ask() })
        defer { Task { await service.release() } }

        panel.warmWhenIdle()
        try await settle(panel)

        #expect(factory.blocked <= Self.frame, "the warm-up held the main thread \(factory.blocked) on the panel service")
        #expect(factory.calls == 0, "the warm-up made a panel before the service answered")
        #expect(panel.stoppedWarming, "the warm-up did not give up at the service deadline")
        #expect(!panel.isMade)
        panel.warmWhenIdle()
        #expect(!panel.isWarming, "a warm-up that failed started again in the same launch")
    }

    @Test func aPanelThatDoesNotComeBackStopsTheWarmUpForTheLaunch() async throws {
        let factory = Factory(wait: 0)
        let panel = MadeAheadOpenPanel(world: world(factory) { true })

        panel.warmWhenIdle()
        try await settle(panel)

        #expect(factory.calls == 1)
        #expect(panel.stoppedWarming, "no panel came back, yet the warm-up goes on")
        panel.warmWhenIdle()
        #expect(!panel.isWarming)
        #expect(factory.calls == 1)
    }
}
