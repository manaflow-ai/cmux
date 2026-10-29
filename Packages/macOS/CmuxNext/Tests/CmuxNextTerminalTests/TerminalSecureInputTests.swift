import CmuxNextCompat
import Foundation
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
import GhosttyNextKit
import Testing

/// Ghostty's secure keyboard entry closes the trace runtime's keystroke-timing gate: the
/// production wiring, ``TerminalSecureInput``, with a test runtime and a test switch in place of HIToolbox's.
@MainActor
@Suite struct TerminalSecureInputTests {
    /// Counts the system switch's calls.
    private final class SwitchCalls: Sendable {
        let enables = Atomic<Int>(0)
        let disables = Atomic<Int>(0)

        var system: TerminalSecureInput.System {
            TerminalSecureInput.System(enable: { _ = self.enables.add(1, ordering: .relaxed) },
                                       disable: { _ = self.disables.add(1, ordering: .relaxed) })
        }
    }

    private func keyRecords(_ runtime: TraceRuntime) -> UInt64 {
        let before = runtime.stubRecordCount.load(ordering: .relaxed)
        for _ in 0 ..< 100 { runtime.write(name: 6, categoryBit: 1, phase: .instant) }
        return runtime.stubRecordCount.load(ordering: .relaxed) - before
    }

    @Test("SECURE_INPUT_ON writes 0 key records; the gate reopens only when the last secure view is gone")
    func secureInputClosesTheGateUntilTheLastViewLetsGo() {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategories(.blackBox)
        let calls = SwitchCalls()
        let secureInput = TerminalSecureInput(trace: runtime, system: calls.system)
        let views = (NSObject(), NSObject())  // alive for the whole test, so their identifiers stay distinct
        let first = ObjectIdentifier(views.0), second = ObjectIdentifier(views.1)

        secureInput.apply(GHOSTTY_SECURE_INPUT_ON, for: first)
        #expect(runtime.keyTimingHolds == .terminalSecureInput)
        #expect(keyRecords(runtime) == 0)
        secureInput.apply(GHOSTTY_SECURE_INPUT_TOGGLE, for: second)
        secureInput.apply(GHOSTTY_SECURE_INPUT_OFF, for: first)
        #expect(runtime.isKeyTimingSuppressed, "the second view still holds secure input")
        #expect(keyRecords(runtime) == 0)
        #expect(calls.enables.load(ordering: .relaxed) == 1 && calls.disables.load(ordering: .relaxed) == 0)

        secureInput.release(second)
        #expect(!runtime.isKeyTimingSuppressed)
        #expect(calls.disables.load(ordering: .relaxed) == 1)
        #expect(keyRecords(runtime) == 100)

        secureInput.apply(GHOSTTY_SECURE_INPUT_TOGGLE, for: first)
        #expect(runtime.isKeyTimingSuppressed)
        secureInput.apply(GHOSTTY_SECURE_INPUT_TOGGLE, for: first)
        #expect(!runtime.isKeyTimingSuppressed)
        #expect(calls.enables.load(ordering: .relaxed) == 2 && calls.disables.load(ordering: .relaxed) == 2)
        secureInput.release(first)
        #expect(calls.disables.load(ordering: .relaxed) == 2, "releasing a view with no request changes nothing")
    }

    @Test("Turning terminal secure input off keeps the gate closed while the system still reports secure input")
    func anotherHoldOutlivesTheTerminals() {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategories(.blackBox)
        let secureInput = TerminalSecureInput(trace: runtime, system: SwitchCalls().system)
        let surface = NSObject()
        let view = ObjectIdentifier(surface)
        runtime.setKeyTimingSuppressed(true, by: .secureEventInput)  // a focused Chromium password field
        secureInput.apply(GHOSTTY_SECURE_INPUT_ON, for: view)
        secureInput.apply(GHOSTTY_SECURE_INPUT_OFF, for: view)
        #expect(runtime.keyTimingHolds == .secureEventInput)
        #expect(keyRecords(runtime) == 0)
        runtime.setKeyTimingSuppressed(false, by: .secureEventInput)
        #expect(keyRecords(runtime) == 100)
    }
}
