import AppKit
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing
@testable import CmuxNextAgentPane

/// Drive the production renderer's queued host callbacks, including callbacks delivered after
/// adoption or cancellation. No window-server timing or copied lifecycle decision is involved.
@MainActor
struct AgentPaneNewTabPrefetchTests {
    private let full = CGSize(width: 1000, height: 800)
    private let split = CGSize(width: 500, height: 800)

    private final class Host {
        var owns = true
        var valid = true
        var sizes: [CGSize] = []
        var draws: [@MainActor () -> Void] = []
        var captures: [(valid: @MainActor () -> Bool, done: @MainActor () -> Void)] = []
        var finished = 0
        var invalidated = 0
        func start(_ renderer: AgentPaneNewTabPrefetch, full: CGSize, split: CGSize) {
            renderer.start(full: full, plan: [split, full], owns: { self.owns }, valid: { self.valid },
                           resize: { self.sizes.append($0) }, whenDrawn: { self.draws.append($0) },
                           capture: { self.captures.append(($0, $1)) },
                           finished: { self.finished += 1 }, invalidated: { self.invalidated += 1 })
        }
    }

    @Test func cancellationWhileAdoptingRejectsTheQueuedCaptureAndNeverResizes() {
        let host = Host(), renderer = AgentPaneNewTabPrefetch()
        host.start(renderer, full: full, split: split)
        host.draws.removeFirst()()
        #expect(host.captures.count == 1)
        renderer.cancel()
        host.owns = false
        #expect(!host.captures[0].valid())
        host.captures.removeFirst().done()
        #expect(host.sizes == [split])
        #expect(!renderer.active)
        #expect(host.finished == 0)
    }

    @Test func changedContextBeforeDrawingRestoresFullSizeWithoutCapturing() {
        let host = Host(), renderer = AgentPaneNewTabPrefetch()
        host.start(renderer, full: full, split: split)
        host.valid = false
        host.draws.removeFirst()()
        #expect(host.sizes == [split, full])
        #expect(host.captures.isEmpty)
        #expect(host.invalidated == 1)
        #expect(!renderer.active)
    }

    @Test func changedGenerationOrAppearanceDuringCaptureRejectsItAndRestoresFullSize() {
        let host = Host(), renderer = AgentPaneNewTabPrefetch()
        host.start(renderer, full: full, split: split)
        host.draws.removeFirst()()
        host.valid = false
        #expect(!host.captures[0].valid())
        host.captures.removeFirst().done()
        #expect(host.sizes == [split, full])
        #expect(host.invalidated == 1)
        #expect(!renderer.active)
    }

    @Test func stalledFrameDeadlineRestoresFullSizeAndDropsLateDrawing() async throws {
        let clock = ManualClock(), host = Host()
        let renderer = AgentPaneNewTabPrefetch(deadline: DemandTimer(owner: "NewTabPrefetchTests", clock: clock))
        host.start(renderer, full: full, split: split)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3))
        for _ in 0..<1000 where renderer.active { await Task.yield() }
        #expect(!renderer.active)
        #expect(host.sizes == [split, full])
        #expect(host.invalidated == 1)
        host.draws.removeFirst()()
        #expect(host.captures.isEmpty)
    }

    @Test func eachSizeWaitsForItsDrawAndCaptureBeforeTheNextResize() {
        let host = Host(), renderer = AgentPaneNewTabPrefetch()
        host.start(renderer, full: full, split: split)
        #expect(host.sizes == [split])
        #expect(host.captures.isEmpty)
        host.draws.removeFirst()()
        #expect(host.sizes == [split])
        #expect(host.captures[0].valid())
        host.captures.removeFirst().done()
        #expect(host.sizes == [split, full])
        host.draws.removeFirst()()
        host.captures.removeFirst().done()
        #expect(host.finished == 1)
        #expect(!renderer.active)
    }

    @Test func synchronousOldSizeDrawCannotCaptureBeforeFitting() {
        let renderer = AgentPaneNewTabPrefetch()
        var size = full
        var captured: [CGSize] = []
        var fitted: [CGSize] = []
        var finished = false
        renderer.start(full: full, plan: [split, full], owns: { true }, valid: { true },
                       resize: { size = $0; fitted.append($0) }, whenDrawn: { $0() },
                       capture: { valid, done in
                           #expect(valid())
                           captured.append(size)
                           done()
                       }, finished: { finished = true }, invalidated: { Issue.record("unexpected invalidation") })
        #expect(captured == [split, full])
        #expect(fitted == [split, full])
        #expect(finished)
        #expect(!renderer.active)
    }
}
