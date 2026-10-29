@testable import CmuxNextSignposts
import Testing

/// The MetricKit mirror sees the intervals the app really emits (the action intervals, typed
/// message included) while on, nothing while off, and never per-frame or per-pump intervals.
/// Each test switches its own mirror, never ``SignpostMetricKitMirror/shared``, so suites that run
/// in parallel never see a mirror a test turned on.
struct SignpostMetricKitMirrorTests {
    private let message = ActionSignpostMessage(id: "test.action", origin: "user", inputAgeMilliseconds: -1)
    private let mirror = SignpostMetricKitMirror()

    private func signposter(_ category: SignpostCategory) -> Signposter { Signposter(category: category, mirror: mirror) }

    @Test func offMirrorsNothing() {
        let interval = signposter(.action).begin(.actionPerform, message)
        #expect(!interval.isMirrored)
        signposter(.action).end(.actionPerform, interval)
    }

    @Test func actionIntervalsReachTheMirrorWhileOn() {
        mirror.setOn(true)
        let action = signposter(.action)
        let perform = action.begin(.actionPerform, message)
        #expect(perform.isMirrored)
        action.end(.actionPerform, perform)
        let commit = action.begin(.actionCommit, message)
        #expect(commit.isMirrored)
        action.end(.actionCommit, commit, .committed)
        let gate = action.begin(.actionGate, "id=test.action")
        #expect(gate.isMirrored)
        action.end(.actionGate, gate)
        #expect(action.interval(.actionPerform, message) { 7 } == 7)
    }

    @Test func perFrameAndPerPumpIntervalsAreNotMirrored() {
        mirror.setOn(true)
        #expect(!SignpostMetricKitMirror.mirrors(.motionFrame))
        #expect(!SignpostMetricKitMirror.mirrors(.cefPump))
        #expect(SignpostMetricKitMirror.mirrors(.actionPerform))
        #expect(SignpostMetricKitMirror.mirrors(.switchWorkspace))
        let frame = signposter(.motion).begin(.motionFrame)
        #expect(!frame.isMirrored)
        signposter(.motion).end(.motionFrame, frame)
        let pump = signposter(.cef).begin(.cefPump)
        #expect(!pump.isMirrored)
        signposter(.cef).end(.cefPump, pump)
    }
}
