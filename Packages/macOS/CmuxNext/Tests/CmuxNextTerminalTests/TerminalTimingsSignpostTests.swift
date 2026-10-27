import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
import Testing

/// A terminal surface create is one `stall.create_surface` thread slice (B/E) whose reported duration is measured on
/// the slice's own clock, and each phase of the runtime's start one `stall.ghostty_runtime_phase` instant
/// (p09-observability task 035).
@MainActor
struct TerminalTimingsSignpostTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime with only the stall category on, recording into this log.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.stall.traceBit))
            return runtime
        }
    }

    /// A clock that advances `step` nanoseconds per read, from 0.
    nonisolated final class SteppingClock: Sendable {
        private let reads = Mutex<UInt64>(0)
        private let step: UInt64

        init(step: UInt64) { self.step = step }

        func traceClock() -> TraceClock {
            TraceClock(reader: .init(uptimeNanos: { [self] in
                reads.withLock { value in
                    value += step
                    return value
                }
            }, continuousNow: { ContinuousClock.now }))
        }
    }

    private func signposter(_ log: RecordLog, clock: TraceClock = TraceClock()) -> Signposter {
        Signposter(category: .stall, mirror: SignpostMetricKitMirror(), trace: log.runtime(), clock: clock)
    }

    @Test("A surface create is one B and one E and reports the slice's own duration")
    func aSurfaceCreateIsOneThreadSlice() {
        let log = RecordLog()
        var reported: [Duration] = []
        let timings = TerminalTimings(stall: signposter(log, clock: SteppingClock(step: 1_500_000).traceClock()),
                                      report: { reported.append($0) })
        let interval = timings.surfaceCreateBegan()
        timings.surfaceCreated(interval)
        #expect(log.records.map(\.phase) == [.begin, .end])
        #expect(log.records.allSatisfy { $0.name == SignpostName.stallCreateSurface.rawValue })
        #expect(reported == [.nanoseconds(1_500_000)], "one clock read at the begin, one at the end")
    }

    @Test("A runtime start phase is one instant with its code and its duration in ns")
    func aRuntimePhaseIsOneInstant() {
        let log = RecordLog()
        let timings = TerminalTimings(stall: signposter(log), report: { _ in })
        timings.runtimePhaseEnded("config_load", .milliseconds(12) + .nanoseconds(345))
        timings.runtimePhaseEnded("not_a_phase", .seconds(2))
        #expect(log.records.map(\.phase) == [.instant, .instant])
        #expect(log.records.allSatisfy { $0.name == SignpostName.stallGhosttyRuntimePhase.rawValue })
        #expect(log.records.map(\.arg0) == [2, 0])
        #expect(log.records.map(\.arg1) == [12_000_345, 2_000_000_000])
    }

    @Test("With the stall category off nothing reaches the ring, and the duration is still reported")
    func offWritesNothing() {
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { _ in Issue.record("wrote a record") })
        var reported: [Duration] = []
        let timings = TerminalTimings(stall: Signposter(category: .stall, mirror: SignpostMetricKitMirror(), trace: runtime),
                                      report: { reported.append($0) })
        timings.surfaceCreated(timings.surfaceCreateBegan())
        timings.runtimePhaseEnded("app_new", .milliseconds(1))
        #expect(reported.count == 1)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
    }
}
