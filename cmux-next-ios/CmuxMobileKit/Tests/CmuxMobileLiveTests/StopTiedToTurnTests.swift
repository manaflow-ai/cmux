import CmuxMobileAgentChat
import CmuxMobileTransport
import Testing
@testable import CmuxMobileLive

/// Finding on #50262 (Greptile): a Stop that waited for the link must not stop the next turn.
@Suite struct StopTiedToTurnTests {
    @Test func aDelayedStopOnlyAppliesToTheTurnItWasPressedFor() {
        #expect(AcpmuxSessionSource.stopStillApplies(pressedFor: "t1", running: "t1"))
        #expect(!AcpmuxSessionSource.stopStillApplies(pressedFor: "t1", running: "t2"), "the next turn is not stopped")
        #expect(!AcpmuxSessionSource.stopStillApplies(pressedFor: "t1", running: nil), "that work already ended")
        #expect(AcpmuxSessionSource.stopStillApplies(pressedFor: nil, running: "t2"), "unknown at the press: as before")
    }
}

@MainActor
@Suite struct StopReconnectTests {
    private func started(_ turn: String, seq: Int) -> JSONValue {
        .object(["sessionId": .string("s1"), "seq": .number(Double(seq)), "at": .number(2),
                 "dir": .string("mux"), "kind": .string("turn_started"),
                 "msg": .object(["turnId": .string(turn)])])
    }

    @Test func stopCapturesTheTurnBeforeItsTaskStarts() async throws {
        let fixture = ChatPromptBlipTests()
        let mac = ChatPromptBlipTests.Mac()
        let (hub, _, source, store) = try await fixture.openChat(mac)
        defer { withExtendedLifetime((hub, store)) {} }
        source.receive(record: started("t1", seq: 1))
        #expect(source.runningTurnID == "t1")
        source.send(.cancel)
        // No suspension: the next event arrives before the cancel task can run.
        source.receive(record: started("t2", seq: 2))
        for _ in 0..<300 { await Task.yield() }
        #expect(source.runningTurnID == "t2")
        #expect(mac.cancels == 0)
    }

    @Test(arguments: [false, true])
    func firstAttemptRechecksAfterWaitingForConnection(turnChanged: Bool) async throws {
        let fixture = ChatPromptBlipTests()
        let mac = ChatPromptBlipTests.Mac()
        let (hub, link, source, store) = try await fixture.openChat(mac)
        let clock = LinkTestClock()
        defer { clock.stop(); withExtendedLifetime(store) {} }
        source.receive(record: started("t1", seq: 1))
        #expect(source.runningTurnID == "t1")
        await hub.bind(nil)
        hub.steadyClock = clock
        let stop = Task { try await source.perform(.cancel, hub: hub, stoppedTurn: "t1") }
        await fixture.settle { clock.nextDeadline != nil }
        #expect(clock.nextDeadline != nil, "the first attempt is waiting inside liveConnection")
        if turnChanged {
            let applied = await source.applyCatchUpPage(.object([
                "session": .object(["sessionId": .string("s1"), "status": .string("running"), "pending": .array([])]),
                "events": .array([started("t2", seq: 2)]), "hasMore": .bool(false), "lastSeq": .number(2),
            ]))
            #expect(applied)
            #expect(source.runningTurnID == "t2")
        }
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        try await stop.value
        #expect(mac.cancels == (turnChanged ? 0 : 1))
    }
}
