import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The key emitters outside the ring obey the keystroke-timing gate: while secure event
/// input is on, a key-down opens no `key.frame` interval and a flow hop writes nothing, in the log or the ring.
@MainActor
@Suite struct KeyTimingGateSignpostTests {
    /// The secure event input state the key-down samples.
    private final class SecureEventInput {
        var isOn = false
    }

    /// The ring records a test runtime wrote while no ring is attached.
    private nonisolated final class RecordCount: Sendable {
        private let count = Mutex(0)

        func add() { count.withLock { $0 += 1 } }

        var value: Int { count.withLock { $0 } }
    }

    /// A runtime with every category on whose ring records only count.
    private static func countingRuntime() -> (TraceRuntime, RecordCount) {
        let count = RecordCount()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { _ in count.add() })
        runtime.setCategories(.all)
        return (runtime, count)
    }

    @Test("While secure event input is on, a key-down opens no key.frame and a flow hop writes nothing")
    func secureEventInputStopsKeyTiming() {
        let (runtime, count) = Self.countingRuntime()
        let secure = SecureEventInput()
        let key = Signposter(category: .key, mirror: SignpostMetricKitMirror(), trace: runtime)
        let keyFrames = KeyFrameSignpost(signposter: key, secureEventInput: { secure.isOn })

        secure.isOn = true
        keyFrames.begin(target: .terminal, eventTimestamp: 0)
        keyFrames.begin(target: .view, eventTimestamp: 0)
        key.flowHop(.appKeyDispatch, flow: 7, ageMicroseconds: 120)
        #expect(runtime.keyTimingHolds == .secureEventInput)
        #expect(!key.isEnabled)
        #expect(keyFrames.openCount == 0)
        #expect(count.value == 0)

        secure.isOn = false
        keyFrames.begin(target: .terminal, eventTimestamp: 0)
        #expect(runtime.keyTimingHolds.isEmpty)
        #expect(keyFrames.openCount == 1)
        keyFrames.runLoopReached(.beforeWaiting)
        key.flowHop(.appKeyDispatch, flow: 8)
        #expect(count.value == 3, "the key.frame begin and end and the flow hop")
    }

    @Test("Another category's signposter stays on while the key gate is closed")
    func otherCategoriesStayOn() {
        let (runtime, _) = Self.countingRuntime()
        runtime.setKeyTimingSuppressed(true, by: .terminalSecureInput)
        #expect(Signposter(category: .action, mirror: SignpostMetricKitMirror(), trace: runtime).isEnabled)
        #expect(!Signposter(category: .key, mirror: SignpostMetricKitMirror(), trace: runtime).isEnabled)
    }

    @Test("A terminal hold keeps key timing off after secure event input ends")
    func aTerminalHoldOutlivesTheSample() {
        let (runtime, count) = Self.countingRuntime()
        let secure = SecureEventInput()
        let keyFrames = KeyFrameSignpost(signposter: Signposter(category: .key, mirror: SignpostMetricKitMirror(), trace: runtime),
                                         secureEventInput: { secure.isOn })
        runtime.setKeyTimingSuppressed(true, by: .terminalSecureInput)
        secure.isOn = true
        keyFrames.begin(target: .terminal, eventTimestamp: 0)
        secure.isOn = false
        keyFrames.begin(target: .terminal, eventTimestamp: 0)
        #expect(runtime.keyTimingHolds == .terminalSecureInput)
        #expect(keyFrames.openCount == 0)
        #expect(count.value == 0)
    }
}
