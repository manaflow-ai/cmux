import Testing
@testable import CmuxNextAgentCursor

@Suite struct AgentCursorLeaseRouterTests {
    @Test func oneTargetDrivesPausesAndEnds() {
        var router = AgentCursorLeaseRouter()
        #expect(router.leaseChanged(target: "t1", session: "s1", wireState: "driving") == [.init(session: "s1", state: .driving)])
        #expect(router.leaseChanged(target: "t1", session: "s1", wireState: "driving") == [], "no change, no update")
        #expect(router.leaseChanged(target: "t1", session: "s1", wireState: "paused") == [.init(session: "s1", state: .paused)])
        #expect(router.leaseChanged(target: "t1", session: "s1", wireState: "user_driving") == [.init(session: "s1", state: .userDriving)])
        #expect(router.leaseChanged(target: "t1", session: nil, wireState: nil) == [.init(session: "s1", state: nil)])
        #expect(router.leaseChanged(target: "t1", session: nil, wireState: nil) == [])
    }

    @Test func aSessionWithTwoTargetsIsPausedOnlyWhenBothArePaused() {
        var router = AgentCursorLeaseRouter()
        _ = router.leaseChanged(target: "t1", session: "s1", wireState: "driving")
        #expect(router.leaseChanged(target: "t2", session: "s1", wireState: "driving") == [])
        #expect(router.leaseChanged(target: "t1", session: "s1", wireState: "paused") == [], "t2 still drives")
        #expect(router.leaseChanged(target: "t2", session: "s1", wireState: "paused") == [.init(session: "s1", state: .paused)])
        #expect(router.leaseChanged(target: "t2", session: nil, wireState: nil) == [], "t1 still holds a paused lease")
        #expect(router.leaseChanged(target: "t1", session: nil, wireState: nil) == [.init(session: "s1", state: nil)])
    }

    @Test func aTargetChangingHandsFromOneSessionToAnotherUpdatesBoth() {
        var router = AgentCursorLeaseRouter()
        _ = router.leaseChanged(target: "t1", session: "a", wireState: "driving")
        #expect(router.leaseChanged(target: "t1", session: "b", wireState: "driving") == [
            .init(session: "a", state: nil), .init(session: "b", state: .driving),
        ])
    }

    /// v4 frame shape: a clear carries no session; session names repeat
    /// across a reset.
    @Test func reopeningTheSameSessionAfterAClearLeavesOneLiveState() {
        var router = AgentCursorLeaseRouter()
        #expect(router.leaseChanged(target: "t1", session: "s1", wireState: "driving") == [.init(session: "s1", state: .driving)])
        #expect(router.leaseChanged(target: "t1", session: nil, wireState: nil) == [.init(session: "s1", state: nil)])
        #expect(router.leaseChanged(target: "t1", session: "s1", wireState: "driving") == [.init(session: "s1", state: .driving)])
        #expect(router.leaseChanged(target: "t1", session: nil, wireState: nil) == [.init(session: "s1", state: nil)])
    }

    @Test func unknownOrMissingWireStatesDrawAsDriving() {
        #expect(AgentCursorLeaseRouter.state(wire: nil) == .driving)
        #expect(AgentCursorLeaseRouter.state(wire: "future_state") == .driving)
    }
}
