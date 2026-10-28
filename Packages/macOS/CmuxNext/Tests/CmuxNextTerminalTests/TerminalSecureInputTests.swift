import CmuxNextCompat
import Foundation
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
import GhosttyNextKit
import Testing

/// Ghostty's secure keyboard entry closes the trace runtime's keystroke-timing gate (p09-observability-128): the
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
        let secureInput = TerminalSecureInput(trace: runtime, system: calls.system, appActive: true)
        let views = (NSObject(), NSObject())  // alive for the whole test, so their identifiers stay distinct
        let first = ObjectIdentifier(views.0), second = ObjectIdentifier(views.1)
        secureInput.setFocused(true, for: first)
        secureInput.setFocused(true, for: second)

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

    @Test("A password prompt in a terminal without keyboard focus leaves the system's secure input off")
    func anUnfocusedTerminalDoesNotTakeSystemSecureInput() {
        // Ghostty asks for secure input when a program in ANY terminal reads a password (sudo in a
        // background tab). System secure input is process-wide and blocks every other app's key taps
        // (hotkeys, text expansion), so only the terminal the person types in may hold it, as Ghostty
        // scopes it (macos/Sources/Features/Secure Input/SecureInput.swift).
        let runtime = TraceRuntime(role: .app)
        let calls = SwitchCalls()
        let secureInput = TerminalSecureInput(trace: runtime, system: calls.system, appActive: true)
        let surface = NSObject()
        secureInput.apply(GHOSTTY_SECURE_INPUT_ON, for: ObjectIdentifier(surface))
        #expect(calls.enables.load(ordering: .relaxed) == 0, "no terminal has keyboard focus")
        #expect(runtime.isKeyTimingSuppressed, "the key-timing gate still closes for the request")
        secureInput.release(ObjectIdentifier(surface))
    }

    @Test("System secure input follows the requesting terminal's focus and the app's activation, balanced")
    func systemSecureInputFollowsFocusAndActivation() {
        let runtime = TraceRuntime(role: .app)
        let calls = SwitchCalls()
        let secureInput = TerminalSecureInput(trace: runtime, system: calls.system, appActive: true)
        let views = (NSObject(), NSObject())
        let prompt = ObjectIdentifier(views.0), other = ObjectIdentifier(views.1)
        func counts() -> (Int, Int) { (calls.enables.load(ordering: .relaxed), calls.disables.load(ordering: .relaxed)) }

        secureInput.setFocused(true, for: other)
        secureInput.apply(GHOSTTY_SECURE_INPUT_ON, for: prompt)
        #expect(counts() == (0, 0), "the focused terminal asked for nothing")
        secureInput.setFocused(false, for: other)
        secureInput.setFocused(true, for: prompt)
        #expect(counts() == (1, 0), "the person moved to the password prompt")

        secureInput.setAppActive(false)
        #expect(counts() == (1, 1), "an inactive app yields secure input to the app the person uses")
        #expect(runtime.isKeyTimingSuppressed, "the request still holds the key-timing gate")
        secureInput.setAppActive(true)
        #expect(counts() == (2, 1), "taken back when the app is active again")

        secureInput.setFocused(false, for: prompt)
        #expect(counts() == (2, 2), "focus left the prompt (another tab or window)")
        secureInput.setFocused(true, for: prompt)
        #expect(counts() == (3, 2))

        secureInput.release(ObjectIdentifier(views.0))
        #expect(counts() == (3, 3), "a closed prompt lets go")
        #expect(!runtime.isKeyTimingSuppressed)
        secureInput.setFocused(true, for: prompt)
        #expect(counts() == (3, 3), "a released view's focus does not take it again")
    }

    @Test("A request that comes while the app is inactive waits for activation")
    func aRequestWhileInactiveWaitsForActivation() {
        let runtime = TraceRuntime(role: .app)
        let calls = SwitchCalls()
        let secureInput = TerminalSecureInput(trace: runtime, system: calls.system, appActive: false)
        let surface = NSObject()
        let view = ObjectIdentifier(surface)
        secureInput.setFocused(true, for: view)
        secureInput.apply(GHOSTTY_SECURE_INPUT_ON, for: view)
        #expect(calls.enables.load(ordering: .relaxed) == 0)
        secureInput.setAppActive(true)
        #expect(calls.enables.load(ordering: .relaxed) == 1)
        secureInput.apply(GHOSTTY_SECURE_INPUT_OFF, for: view)
        #expect(calls.disables.load(ordering: .relaxed) == 1)
        #expect(!runtime.isKeyTimingSuppressed)
    }

    @Test("Turning terminal secure input off keeps the gate closed while the system still reports secure input")
    func anotherHoldOutlivesTheTerminals() {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategories(.blackBox)
        let secureInput = TerminalSecureInput(trace: runtime, system: SwitchCalls().system, appActive: true)
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
