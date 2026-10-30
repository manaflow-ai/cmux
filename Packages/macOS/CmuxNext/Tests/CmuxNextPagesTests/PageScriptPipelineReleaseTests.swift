import CmuxNextMemory
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextPages

/// The main thread never frees a large run of page envelopes: the last reference to a run the drain
/// task sent or a reset dropped (its envelopes and the drop actions that hold the events) goes to the
/// release sink. The P-MAIN S3 stall (v229, 2026-10-30): `PageScriptPipeline.Drop`'s deinit freed a
/// hidden agent page's released batch on main, 1,375 ms, 23 ms of it on the CPU.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PageScriptPipelineReleaseTests {
    /// Stands for what a drop action holds (the router's held events): its deinit reports whether the
    /// free ran on the main thread.
    private nonisolated final class Probe: Sendable {
        private let released: AsyncStream<Bool>.Continuation

        init(_ released: AsyncStream<Bool>.Continuation) { self.released = released }

        deinit { released.yield(Thread.isMainThread) }
    }

    /// Holds the render of the first run until ``release()``.
    private actor RenderGate {
        private var started = false
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

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

    /// Over the inline budget: the drain task renders and sends it.
    private static func large(_ n: Int) -> JSONValue {
        ["n": .number(Double(n)), "text": .string(String(repeating: "x", count: 20_000))]
    }

    /// Takes `count` results from `stream`.
    private static func first(_ count: Int, of stream: AsyncStream<Bool>) async -> [Bool] {
        var results: [Bool] = []
        for await onMain in stream {
            results.append(onMain)
            if results.count == count { break }
        }
        return results
    }

    /// A long scripted session: 200 large envelopes, each sent by the drain task. Every one is freed,
    /// none on the main thread, and the pipeline keeps none of them after it sent them.
    @Test func everyRunTheDrainSentIsFreedOffMain() async {
        let count = 200
        let (delivered, deliveredOne) = AsyncStream.makeStream(of: Void.self)
        let (released, probeReleased) = AsyncStream.makeStream(of: Bool.self)
        let pipeline = PageScriptPipeline(deliver: { _ in deliveredOne.yield() }, form: { .script })
        pipeline.releaseOffMain(on: MemoryReleaseSink())
        for n in 0..<count {
            let probe = Probe(probeReleased)
            pipeline.send(Self.large(n)) { [probe] in withExtendedLifetime(probe) {} }
        }
        var sent = 0
        for await _ in delivered {
            sent += 1
            if sent == count { break }
        }

        let onMain = await Self.first(count, of: released)
        #expect(onMain.count == count, "the pipeline kept a run it sent")
        #expect(onMain.filter { $0 }.count == 0, "\(onMain.filter { $0 }.count) of \(count) sent runs were freed on the main thread")
    }

    /// A reset drops the run in flight and the queued one; both drop actions run, and both runs are
    /// freed off the main thread.
    @Test func aResetFreesTheRunsItDroppedOffMain() async {
        final class Drops { var names: [String] = [] }
        let gate = RenderGate()
        let (released, probeReleased) = AsyncStream.makeStream(of: Bool.self)
        let drops = Drops()
        let pipeline = PageScriptPipeline(evaluate: { _ in }, render: { envelopes in
            await gate.wait()
            return PageRouter.receiveManyScript(envelopes)
        })
        pipeline.releaseOffMain(on: MemoryReleaseSink())
        // The probe's only holder is the drop action: the test keeps no reference to it.
        func send(_ n: Int, _ name: String) {
            let probe = Probe(probeReleased)
            pipeline.send(Self.large(n)) { [probe] in withExtendedLifetime(probe) { drops.names.append(name) } }
        }
        send(0, "in flight")
        await gate.waitUntilStarted()
        send(1, "queued")

        pipeline.reset()
        #expect(drops.names == ["in flight", "queued"])
        await gate.release()

        let onMain = await Self.first(2, of: released)
        #expect(onMain == [false, false], "a run the reset dropped was freed on the main thread: \(onMain)")
    }
}
