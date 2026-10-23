import CmuxNextSignposts
import Testing

/// The MetricKit mirror sees the intervals the app really emits (the action intervals, typed
/// message included) while on, nothing while off, and never per-frame or per-pump intervals.
@Suite("MetricKit mirror", .serialized)
struct SignpostMetricKitMirrorTests {
    private let message = ActionSignpostMessage(id: "test.action", origin: "user", inputAgeMilliseconds: -1)

    @Test func offMirrorsNothing() {
        SignpostMetricKitMirror.shared.setOn(false)
        let interval = Signposter.action.begin(.actionPerform, message)
        #expect(!interval.isMirrored)
        Signposter.action.end(.actionPerform, interval)
    }

    @Test func actionIntervalsReachTheMirrorWhileOn() {
        let mirror = SignpostMetricKitMirror.shared
        mirror.setOn(true)
        defer { mirror.setOn(false) }
        let perform = Signposter.action.begin(.actionPerform, message)
        #expect(perform.isMirrored)
        Signposter.action.end(.actionPerform, perform)
        let commit = Signposter.action.begin(.actionCommit, message)
        #expect(commit.isMirrored)
        Signposter.action.end(.actionCommit, commit, .committed)
        let gate = Signposter.action.begin(.actionGate, "id=test.action")
        #expect(gate.isMirrored)
        Signposter.action.end(.actionGate, gate)
        #expect(Signposter.action.interval(.actionPerform, message) { 7 } == 7)
    }

    @Test func perFrameAndPerPumpIntervalsAreNotMirrored() {
        let mirror = SignpostMetricKitMirror.shared
        mirror.setOn(true)
        defer { mirror.setOn(false) }
        #expect(!SignpostMetricKitMirror.mirrors(.motionFrame))
        #expect(!SignpostMetricKitMirror.mirrors(.cefPump))
        #expect(SignpostMetricKitMirror.mirrors(.actionPerform))
        #expect(SignpostMetricKitMirror.mirrors(.switchWorkspace))
        let frame = Signposter.motion.begin(.motionFrame)
        #expect(!frame.isMirrored)
        Signposter.motion.end(.motionFrame, frame)
        let pump = Signposter.cef.begin(.cefPump)
        #expect(!pump.isMirrored)
        Signposter.cef.end(.cefPump, pump)
    }
}
