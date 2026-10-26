import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The records a test runtime writes, in order (the stub recorder's fields of a ring record).
private final class PresentationRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

    /// A runtime that records into this log, with every category off.
    func runtime() -> TraceRuntime {
        TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in state.withLock { $0.append(record) } })
    }
}

/// The p03-rendering 004 events: `motion.late_commits` and `action.presented_estimate` write one instant each under
/// their category's flag, numbers only, the estimate marked estimated.
struct SignposterPresentationTests {
    private let mirror = SignpostMetricKitMirror()

    @Test("A late commit is one motion instant with its lateness and turn in us")
    func lateCommitRecord() throws {
        let log = PresentationRecordLog()
        let runtime = log.runtime()
        let motion = Signposter(category: .motion, mirror: mirror, trace: runtime)
        motion.lateCommit(lateMilliseconds: 1.25, turnMilliseconds: 9.5)
        #expect(log.records.isEmpty, "the motion category is off")
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.motion.traceBit))
        motion.lateCommit(lateMilliseconds: 1.25, turnMilliseconds: 9.5)
        let record = try #require(log.records.first)
        #expect(log.records.count == 1)
        #expect(record.name == SignpostName.motionLateCommits.rawValue)
        #expect(record.phase == .instant)
        #expect(record.arg0 == 1_250 && record.arg1 == 9_500)
        #expect(!record.flags.contains(.estimated))
    }

    @Test("An estimated present is one action instant marked estimated, with the index, phase and time")
    func presentEstimateRecord() throws {
        let log = PresentationRecordLog()
        let runtime = log.runtime()
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.action.traceBit))
        let action = Signposter(category: .action, mirror: mirror, trace: runtime)
        let message = ActionPresentSignpostMessage(id: "tab.new", actionIndex: 7, presentMilliseconds: 14,
                                                   commitMilliseconds: 6, inputAgeMilliseconds: 1.5, phase: .recent,
                                                   estimateUptimeNanos: 123_456_789)
        action.presentEstimate(message)
        let record = try #require(log.records.first)
        #expect(log.records.count == 1)
        #expect(record.name == SignpostName.actionPresentedEstimate.rawValue)
        #expect(record.phase == .instant)
        #expect(record.flags.contains(.estimated))
        #expect(record.arg0 == 7 | VsyncPhase.recent.traceCode << 32)
        #expect(record.arg1 == 123_456_789)
    }

    @Test("A negative or non-finite duration records 0 us")
    func microsecondsClamp() {
        #expect(Signposter.microseconds(-1) == 0)
        #expect(Signposter.microseconds(.nan) == 0)
        #expect(Signposter.microseconds(.infinity) == 0)
        #expect(Signposter.microseconds(0.0015) == 1)
    }
}
