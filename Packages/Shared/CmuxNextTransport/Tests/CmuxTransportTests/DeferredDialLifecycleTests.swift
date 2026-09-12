import Testing

@testable import CmuxNextTransport

@Suite("Deferred dials preserve connection ownership")
struct DeferredDialLifecycleTests {
    @Test(arguments: ["timer", "foreground", "push"])
    func automaticTriggerDoesNotReplaceReadyConnection(trigger: String) {
        var machine = readyMachine()
        let generation = machine.activeConnectionGeneration
        _ = machine.handle(.endpointReadyChanged(false))

        #expect(machine.handle(.dialRequested(.automatic(trigger: trigger))).isEmpty)
        #expect(!machine.dialDeferred)
        #expect(machine.handle(.endpointReadyChanged(true)).isEmpty)
        #expect(machine.state == .ready)
        #expect(machine.activeConnectionGeneration == generation)
        #expect(machine.currentAttempt == nil)
    }

    @Test func deferredExplicitIntentClosesItsPreviousConnection() {
        var machine = readyMachine()
        _ = machine.handle(.endpointReadyChanged(false))
        #expect(machine.handle(.dialRequested(.explicit(trigger: "retry"))) == [
            .deferDialUntilEndpointReady,
        ])
        // An ambient event must not erase the user's pending replacement.
        #expect(machine.handle(.dialRequested(.automatic(trigger: "foreground"))).isEmpty)
        #expect(machine.handle(.endpointReadyChanged(true)) == [
            .closeConnection(.explicitRedial), .startDial(AttemptID(raw: 2)),
        ])
        #expect(!machine.dialDeferred)
    }

    @Test func automaticTriggerJoinsExistingAttemptWhileEndpointIsUnavailable() {
        var machine = SessionStateMachine()
        _ = machine.handle(.endpointReadyChanged(true))
        _ = machine.handle(.dialRequested(.automatic(trigger: "launch")))
        _ = machine.handle(.endpointReadyChanged(false))

        #expect(machine.handle(.dialRequested(.automatic(trigger: "foreground"))) == [
            .joinDial(AttemptID(raw: 1)),
        ])
        #expect(machine.handle(.endpointReadyChanged(true)).isEmpty)
        #expect(machine.currentAttempt == AttemptID(raw: 1))
    }

    @Test(.timeLimit(.minutes(1)))
    func liveOwnerKeepsItsAdmittedConnectionAcrossReadinessFlap() async throws {
        let rig = try ReconnectOwnerTests.Rig()
        let owner = ReconnectOwner { try await rig.connectOnce() }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        for await state in await owner.states() where state == .ready { break }
        let first = try #require(await owner.currentConnection)

        await owner.endpointReady(false)
        await owner.trigger(.automatic(trigger: "foreground"))
        await owner.endpointReady(true)

        #expect(await owner.dialsStarted == 1)
        #expect(await owner.currentConnection === first)
        #expect(await owner.state == .ready)
        await owner.stop()
        #expect(await first.isClosed)
    }

    private func readyMachine() -> SessionStateMachine {
        var machine = SessionStateMachine()
        _ = machine.handle(.endpointReadyChanged(true))
        _ = machine.handle(.dialRequested(.automatic(trigger: "launch")))
        _ = machine.handle(.dialSucceeded(AttemptID(raw: 1)))
        return machine
    }
}
