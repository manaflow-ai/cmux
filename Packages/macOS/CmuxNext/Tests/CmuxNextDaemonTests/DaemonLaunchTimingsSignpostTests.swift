import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Foundation
import Testing

/// Each daemon connection mark is one `daemon.step` instant in the trace ring, every time it happens, and none goes
/// out under the launch category (p09-observability task 035): the store resyncs and terminal attaches that recur
/// after launch are not launch steps.
struct DaemonLaunchTimingsSignpostTests {
    /// The records a test runtime writes, in order.
    final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime with every category on, recording into this log.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(SignpostCategory.allCases.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
            return runtime
        }
    }

    /// The mark names a receiver got, in order.
    final class Received: Sendable {
        private let state = Mutex<[String]>([])

        var names: [String] { state.withLock { $0 } }

        func append(_ name: String) { state.withLock { $0.append(name) } }
    }

    private func timings(_ log: RecordLog) -> DaemonLaunchTimings {
        DaemonLaunchTimings(signposter: Signposter(category: .daemon, mirror: SignpostMetricKitMirror(), trace: log.runtime()))
    }

    @Test("A mark is one daemon.step instant whose arg0 is the step's code")
    func aMarkIsOneStepInstant() {
        let log = RecordLog()
        timings(log).mark("daemon.handshake_end")
        #expect(log.records.map(\.name) == [SignpostName.daemonStep.rawValue])
        #expect(log.records.map(\.phase) == [.instant])
        #expect(log.records.first?.arg0 == 13, "daemon.handshake_end is the 13th step of the fixed order")
        #expect(log.records.first?.categoryBit == SignpostCategory.daemon.traceBit)
    }

    @Test("A mark repeated after launch writes again, never under the launch category")
    func recurringMarksAreNotLaunchSteps() {
        let log = RecordLog()
        let timings = timings(log)
        for name in ["daemon.handshake_end", "daemon.snapshot_start", "daemon.snapshot_end", "terminal.attach_start",
                     "terminal.attach_end", "daemon.snapshot_start", "daemon.snapshot_end", "terminal.attach_end"] {
            timings.mark(name)
        }
        #expect(log.records.count == 8)
        #expect(log.records.allSatisfy { $0.name == SignpostName.daemonStep.rawValue })
        #expect(!log.records.contains { $0.categoryBit == SignpostCategory.launch.traceBit })
    }

    @Test("Every step has its own nonzero code; a name outside the list has code 0")
    func codesAreDistinct() {
        let codes = DaemonLaunchTimings.Step.allCases.map { DaemonLaunchTimings.Step.traceCode(of: $0.rawValue) }
        #expect(codes == Array(1...UInt64(codes.count)))
        #expect(DaemonLaunchTimings.Step.traceCode(of: "daemon.not_a_step") == 0)
    }

    @Test("The receiver still gets every mark, the early ones first")
    func theReceiverGetsEveryMark() {
        let log = RecordLog()
        let timings = timings(log)
        let received = Received()
        timings.mark("daemon.connect_start")
        timings.install { name, _ in received.append(name) }
        timings.mark("daemon.handshake_end")
        #expect(received.names == ["daemon.connect_start", "daemon.handshake_end"])
        #expect(log.records.count == 2)
    }
}
