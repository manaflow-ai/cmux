import CmuxNextCompat
import CmuxNextIPC
import Darwin
import Dispatch
import Foundation
import Testing

/// The owner's step runner wraps each drain step of a ``FrameWriter`` exactly once (the owner's hang scope):
/// every send runs inside one step, waiting input and control messages that share a
/// send are one step, each bulk chunk is a step of its own, and nothing waiting in the FIFOs is in a step.
@Suite nonisolated struct FrameWriterStepTests {
    @Test func eachDrainStepRunsInsideOneStepAndEverySendInsideAStep() throws {
        let log = StepLog()
        let sink = StepSink(log: log, expectedBytes: 2 + 6)
        // The drain runs on `target`: suspended, so every message waits in the FIFOs before the first step.
        let target = DispatchQueue(label: "test.frame-writer.steps")
        target.suspend()
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated, target: target,
                                 runStep: { step in log.run(step) })
        defer { writer.close() }

        #expect(writer.enqueue(Data("a".utf8), priority: .control) == nil)
        #expect(writer.enqueue(Data("b".utf8), priority: .input) == nil)
        #expect(writer.enqueue(Data("bk1".utf8), priority: .bulk) == nil)
        #expect(writer.enqueue(Data("bk2".utf8), priority: .bulk) == nil)
        #expect(log.steps == 0, "a message waiting in the FIFOs was inside a step")
        target.resume()
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")
        // The drain is one block on the serial target: this one runs after it returned.
        target.sync {}

        #expect(sink.sendSizes == [2, 3, 3], "input and control share one send, each bulk chunk is its own")
        #expect(log.steps == 3)
        #expect(log.sendDepths == [1, 1, 1], "a send ran outside its step, or inside two")
        #expect(log.depth == 0)
    }

    @Test func noRunnerStillSendsEveryMessage() throws {
        let log = StepLog()
        let sink = StepSink(log: log, expectedBytes: 3)
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated)
        defer { writer.close() }

        #expect(writer.enqueue(Data("abc".utf8), priority: .control) == nil)
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")

        #expect(log.steps == 0)
        #expect(log.sendDepths == [0])
    }
}

/// The steps a runner ran and how deep in steps each send was (touched only on the writer's drain queue,
/// read by the test after the drain).
private nonisolated final class StepLog: Sendable {
    private struct State {
        var depth = 0
        var steps = 0
        var sendDepths: [Int] = []
    }

    private let state = Mutex(State())

    var depth: Int { state.withLock { $0.depth } }
    var steps: Int { state.withLock { $0.steps } }
    var sendDepths: [Int] { state.withLock { $0.sendDepths } }

    func run(_ step: () -> Void) {
        state.withLock { state in
            state.depth += 1
            state.steps += 1
        }
        step()
        state.withLock { $0.depth -= 1 }
    }

    func sent() {
        state.withLock { state in state.sendDepths.append(state.depth) }
    }
}

/// A sink that records each send's size and depth in steps, and signals once every expected byte arrived.
private nonisolated final class StepSink: FrameSink {
    private let log: StepLog
    private let expectedBytes: Int
    private let finished = DispatchSemaphore(value: 0)
    private let recorded = Mutex<(bytes: Int, sizes: [Int])>((0, []))

    init(log: StepLog, expectedBytes: Int) {
        self.log = log
        self.expectedBytes = expectedBytes
    }

    func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        log.sent()
        let total = recorded.withLock { recorded -> Int in
            recorded.bytes += bytes.count
            recorded.sizes.append(bytes.count)
            return recorded.bytes
        }
        if total == expectedBytes { finished.signal() }
        return .success(bytes.count)
    }

    /// True once the expected byte count arrived (within 10 s).
    func waitUntilFinished() -> Bool { finished.wait(timeout: .now() + 10) == .success }

    var sendSizes: [Int] { recorded.withLock { $0.sizes } }
}
