import Foundation
import CmuxNextSettings
import Testing
@testable import CmuxNextPages

@MainActor
struct PageScriptPipelineTests {
    private actor RenderGate {
        var started = false
        var startedWaiter: CheckedContinuation<Void, Never>?
        var releaseWaiter: CheckedContinuation<Void, Never>?

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startedWaiter = $0 }
        }

        func wait() async {
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    @Test func resetDropsInFlightBeforeLaterQueuedEnvelope() async {
        let gate = RenderGate()
        var drops: [String] = []
        let pipeline = PageScriptPipeline(evaluate: { _ in }, render: { envelope in
            await gate.wait()
            return PageRouter.receiveScript(envelope)
        })
        let large = JSONValue.string(String(repeating: "x", count: 20_000))
        pipeline.send(large) { drops.append("first") }
        await gate.waitUntilStarted()
        pipeline.send(.string("later")) { drops.append("second") }

        pipeline.reset()
        #expect(drops == ["first", "second"])
        await gate.release()
    }

    @Test func resetOpensAnInFlightGate() async {
        let pipeline = PageScriptPipeline(evaluate: { _ in })
        pipeline.send(JSONValue.string(String(repeating: "x", count: 20_000)))
        let gate = pipeline.gate(always: true)
        let reached = await Task { await gate?.reached(); return true }.value
        #expect(reached)
        let opened = Task { await gate?.opened(); return true }
        pipeline.reset()
        #expect(await opened.value)
    }
}
