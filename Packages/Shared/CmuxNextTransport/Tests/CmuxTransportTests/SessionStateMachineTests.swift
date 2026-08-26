import Foundation
import Testing

@testable import CmuxNextTransport

@Suite("Session state machine (contract 4.x)")
struct SessionStateMachineTests {
    @Test("No dial before the endpoint is ready; deferred dial fires on ready (2.4)")
    func dialDeferredUntilEndpointReady() {
        var machine = SessionStateMachine()
        let deferred = machine.handle(.dialRequested(.automatic(trigger: "launch")))
        #expect(deferred == [.deferDialUntilEndpointReady])
        #expect(machine.state == .connecting)
        #expect(machine.currentAttempt == nil)

        let onReady = machine.handle(.endpointReadyChanged(true))
        #expect(onReady == [.startDial(AttemptID(raw: 1))])
        #expect(machine.currentAttempt == AttemptID(raw: 1))
    }

    @Test("Automatic triggers JOIN the in-flight attempt, never race it (4.3)")
    func automaticDialJoins() {
        var machine = SessionStateMachine()
        _ = machine.handle(.endpointReadyChanged(true))
        let first = machine.handle(.dialRequested(.automatic(trigger: "launch")))
        #expect(first == [.startDial(AttemptID(raw: 1))])

        // The supersede storm: foreground + push + event-stream-ended all
        // arriving while a dial is in flight. All three must join.
        for trigger in ["foreground", "push", "event-stream-ended"] {
            let effects = machine.handle(.dialRequested(.automatic(trigger: trigger)))
            #expect(effects == [.joinDial(AttemptID(raw: 1))])
        }
        #expect(machine.currentAttempt == AttemptID(raw: 1))
    }

    @Test("Explicit intent replaces the in-flight attempt (4.3)")
    func explicitDialReplaces() {
        var machine = SessionStateMachine()
        _ = machine.handle(.endpointReadyChanged(true))
        _ = machine.handle(.dialRequested(.automatic(trigger: "launch")))

        let effects = machine.handle(.dialRequested(.explicit(trigger: "manual-retry")))
        #expect(effects == [.cancelDial(AttemptID(raw: 1)), .startDial(AttemptID(raw: 2))])
        #expect(machine.currentAttempt == AttemptID(raw: 2))
    }

    @Test("Automatic dial while ready is a no-op: retry loops stop on success (4.6)")
    func automaticDialWhileReadyIsNoOp() {
        var machine = readyMachine()
        // The field logs showed a ~2s dial loop churning against a live
        // session (207 of 286 failures happened while connected).
        for _ in 0..<5 {
            let effects = machine.handle(.dialRequested(.automatic(trigger: "timer")))
            #expect(effects.isEmpty)
            #expect(machine.state == .ready)
        }
    }

    @Test("Dial success transitions to ready; stale attempt results are recorded, not applied")
    func dialSuccessAndStaleAttempts() {
        var machine = SessionStateMachine()
        _ = machine.handle(.endpointReadyChanged(true))
        _ = machine.handle(.dialRequested(.automatic(trigger: "launch")))
        _ = machine.handle(.dialRequested(.explicit(trigger: "manual-retry")))

        // The replaced attempt (1) reports success late: must be ignored.
        let stale = machine.handle(.dialSucceeded(AttemptID(raw: 1)))
        #expect(stale == [.invalidEventRecorded("dialSucceeded for stale attempt 1")])
        #expect(machine.state == .connecting)

        let current = machine.handle(.dialSucceeded(AttemptID(raw: 2)))
        #expect(current.isEmpty)
        #expect(machine.state == .ready)
    }

    @Test("Dial failure returns to idle; the owner schedules the next attempt (4.6)")
    func dialFailureReturnsToIdle() {
        var machine = SessionStateMachine()
        _ = machine.handle(.endpointReadyChanged(true))
        _ = machine.handle(.dialRequested(.automatic(trigger: "launch")))
        let effects = machine.handle(.dialFailed(AttemptID(raw: 1), code: "timeout"))
        #expect(effects.isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.currentAttempt == nil)
    }

    @Test("Remote close carries its attributed reason (4.4, 4.5)")
    func remoteCloseKeepsReason() {
        var machine = readyMachine()
        _ = machine.handle(.remoteClosed(.superseded))
        #expect(machine.state == .closed(.superseded))
    }

    @Test("Local close cancels the in-flight dial and attributes the close (4.4)")
    func localCloseCancelsDial() {
        var machine = SessionStateMachine()
        _ = machine.handle(.endpointReadyChanged(true))
        _ = machine.handle(.dialRequested(.automatic(trigger: "launch")))
        let effects = machine.handle(.closeRequested(.modeSwitched))
        #expect(effects == [
            .cancelDial(AttemptID(raw: 1)),
            .closeConnection(.modeSwitched),
        ])
        #expect(machine.state == .closed(.modeSwitched))
    }

    @Test("Degraded and recovered round-trip (4.2)")
    func degradeRecover() {
        var machine = readyMachine()
        _ = machine.handle(.connectionDegraded(.pathLost))
        #expect(machine.state == .degraded(.pathLost))
        _ = machine.handle(.connectionRecovered)
        #expect(machine.state == .ready)
    }

    @Test("The machine is total: every event in every state stays inside the five states")
    func totality() {
        let events: [SessionEvent] = [
            .endpointReadyChanged(true),
            .endpointReadyChanged(false),
            .dialRequested(.automatic(trigger: "t")),
            .dialRequested(.explicit(trigger: "t")),
            .dialSucceeded(AttemptID(raw: 1)),
            .dialFailed(AttemptID(raw: 1), code: "x"),
            .connectionDegraded(.networkUnavailable),
            .connectionRecovered,
            .closeRequested(.userRequested),
            .remoteClosed(.superseded),
        ]
        // Drive every event from every reachable seed state, twice over.
        for seedEvents in eventSequences() {
            var machine = SessionStateMachine()
            for event in seedEvents { _ = machine.handle(event) }
            for event in events + events {
                _ = machine.handle(event)
                switch machine.state {
                case .idle, .connecting, .ready, .degraded, .closed:
                    break  // the five states; associated values carry the detail
                }
            }
        }
    }

    private func eventSequences() -> [[SessionEvent]] {
        [
            [],
            [.endpointReadyChanged(true)],
            [.endpointReadyChanged(true), .dialRequested(.automatic(trigger: "launch"))],
            [
                .endpointReadyChanged(true), .dialRequested(.automatic(trigger: "launch")),
                .dialSucceeded(AttemptID(raw: 1)),
            ],
            [
                .endpointReadyChanged(true), .dialRequested(.automatic(trigger: "launch")),
                .dialSucceeded(AttemptID(raw: 1)), .connectionDegraded(.pathLost),
            ],
            [
                .endpointReadyChanged(true), .dialRequested(.automatic(trigger: "launch")),
                .dialSucceeded(AttemptID(raw: 1)), .remoteClosed(.superseded),
            ],
        ]
    }

    private func readyMachine() -> SessionStateMachine {
        var machine = SessionStateMachine()
        _ = machine.handle(.endpointReadyChanged(true))
        _ = machine.handle(.dialRequested(.automatic(trigger: "launch")))
        _ = machine.handle(.dialSucceeded(AttemptID(raw: 1)))
        return machine
    }
}
