import Testing

@testable import CmuxBrowser

@MainActor
@Suite struct ChromiumFocusReentrancyGateTests {
    @Test func runsSequentialBodies() {
        let gate = ChromiumFocusReentrancyGate()
        var runs = 0
        #expect(gate.run { runs += 1 })
        #expect(gate.run { runs += 1 })
        #expect(runs == 2)
        #expect(!gate.isRunning)
    }

    @Test func dropsReentrantBody() {
        let gate = ChromiumFocusReentrancyGate()
        var inner: Bool?
        gate.run {
            #expect(gate.isRunning)
            inner = gate.run { Issue.record("re-entrant body ran") }
        }
        #expect(inner == false)
        #expect(!gate.isRunning)
    }

    /// The P0 crash: SetFocus makes the page window key, the pane makes its
    /// window key again, and cmux's becomeKey handler focuses the page again.
    /// Ungated, that cycle only ends when the stack overflows.
    @Test func breaksTheFocusKeyWindowCycle() {
        let gate = ChromiumFocusReentrancyGate()
        var focusCalls = 0
        var reclaimCalls = 0
        var focusPage: () -> Void = {}
        let pageWindowBecameKey = {
            gate.run {
                reclaimCalls += 1
                // cmux window becomeKey -> restore panel focus -> page focus.
                focusPage()
            }
        }
        focusPage = {
            gate.run {
                focusCalls += 1
                // Chromium SetFocus -> page window key notification.
                pageWindowBecameKey()
            }
        }
        focusPage()
        #expect(focusCalls == 1)
        #expect(reclaimCalls == 0)
        // Starting from the pane side, the page focus inside it is dropped.
        pageWindowBecameKey()
        #expect(reclaimCalls == 1)
        #expect(focusCalls == 1)
        #expect(!gate.isRunning)
    }
}
