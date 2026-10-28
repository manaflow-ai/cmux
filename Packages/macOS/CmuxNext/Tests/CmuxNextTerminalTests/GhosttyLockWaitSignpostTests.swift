import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
import Testing

/// Each input wait ghostty-next reports for its terminal lock is one `ghostty.lock_wait` instant with the wait in
/// ns, and nothing reaches the ring while the ghostty category is off.
@MainActor
struct GhosttyLockWaitSignpostTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime with only the ghostty category on, recording into this log.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.ghostty.traceBit))
            return runtime
        }
    }

    @Test("A reported wait is one ghostty.lock_wait instant whose arg0 is the wait in ns")
    func aWaitIsOneInstant() {
        let log = RecordLog()
        let signpost = GhosttyLockWaitSignpost(
            signposter: Signposter(category: .ghostty, mirror: SignpostMetricKitMirror(), trace: log.runtime()))
        signpost.record(nanos: 72_500)
        signpost.record(nanos: 1_200_000)
        #expect(log.records.map(\.phase) == [.instant, .instant])
        #expect(log.records.allSatisfy { $0.name == SignpostName.ghosttyLockWait.rawValue })
        #expect(log.records.map(\.arg0) == [72_500, 1_200_000])
    }

    @Test("With the ghostty category off a wait writes nothing")
    func offWritesNothing() {
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { _ in Issue.record("wrote a record") })
        GhosttyLockWaitSignpost(signposter: Signposter(category: .ghostty, mirror: SignpostMetricKitMirror(), trace: runtime))
            .record(nanos: 90_000)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
    }

    @Test("ghostty.lock_wait is in the ghostty category with ring id 87")
    func catalogEntry() {
        #expect(SignpostName.ghosttyLockWait.rawValue == 87)
        #expect(SignpostName.ghosttyLockWait.traceCategory == .ghostty)
        #expect(SignpostName.ghosttyLockWait.description == "ghostty.lock_wait")
        #expect(!SignpostName.ghosttyLockWait.opensThreadSlice)
        #expect(GhosttyLockWaitSignpost().signposter.category == .ghostty)
    }
}
