import Testing

@testable import CmuxCEF

@MainActor
@Suite struct ChromiumFocusReentrancyGateTests {
    @Test func runsSequentialBodies() {
        let gate = ChromiumFocusReentrancyGate()
        var runs = 0
        #expect(gate.run { runs += 1 })
        gate.runOrDefer { runs += 1 }
        #expect(runs == 2)
        #expect(!gate.isRunning)
    }

    @Test func dropsReentrantReclaim() {
        let gate = ChromiumFocusReentrancyGate()
        var inner: Bool?
        gate.run {
            #expect(gate.isRunning)
            inner = gate.run { Issue.record("re-entrant reclaim ran") }
        }
        #expect(inner == false)
        #expect(!gate.isRunning)
    }

    /// The P0 crash: SetFocus makes the page window key, the pane makes its
    /// window key again, and cmux's becomeKey handler focuses the page again.
    /// Ungated, that cycle only ends when the stack overflows.
    @Test func breaksTheFocusKeyWindowCycle() {
        let gate = ChromiumFocusReentrancyGate()
        var setFocusCalls = 0
        var reclaimCalls = 0
        var grantFocus: () -> Void = {}
        let pageWindowBecameKey = {
            gate.run {
                reclaimCalls += 1
                // cmux window becomeKey -> restore panel focus -> page focus.
                grantFocus()
            }
        }
        grantFocus = {
            gate.runOrDefer {
                setFocusCalls += 1
                // Chromium SetFocus -> page window key notification.
                pageWindowBecameKey()
            }
        }
        grantFocus()
        #expect(setFocusCalls == 1)
        #expect(reclaimCalls == 0)
        // From the pane side: the focus request inside the reclaim runs once
        // after it, and the reclaim that SetFocus triggers then is dropped.
        pageWindowBecameKey()
        #expect(reclaimCalls == 1)
        #expect(setFocusCalls == 2)
        #expect(!gate.isRunning)
    }

    /// A page cmux asks to focus during another gated change still gets the
    /// keys once that change is done; only the latest request runs.
    @Test func replaysLatestDeferredFocusOnce() {
        let gate = ChromiumFocusReentrancyGate()
        var focused: [String] = []
        gate.run {
            gate.runOrDefer { focused.append("a") }
            gate.runOrDefer {
                focused.append("c")
                // A request the replay itself starts is dropped.
                gate.runOrDefer { focused.append("again") }
            }
            #expect(focused.isEmpty)
        }
        #expect(focused == ["c"])
        #expect(!gate.isRunning)
        gate.runOrDefer { focused.append("next") }
        #expect(focused == ["c", "next"])
    }
}
