import CmuxAgentCursor
import Testing
@testable import CmuxNextAgentCursor

@Suite struct AgentCursorDemoTests {
    @Test func inputActionsBecomeEventsWithGapFreeSeq() throws {
        var demo = AgentCursorDemo()
        let move = try demo.step(action: "move", session: "demo", target: "tab_1", x: 10, y: 20, tMs: 1)
        let click = try demo.step(action: "click", session: "demo", target: "tab_1", x: 30, y: 40, zoom: 1.5, tMs: 2)
        let typed = try demo.step(action: "type", session: "demo", target: "tab_1", x: nil, y: nil, tMs: 3)
        guard case let .input(a) = move, case let .input(b) = click, case let .input(c) = typed else {
            Issue.record("expected input steps")
            return
        }
        #expect((a.seq, b.seq, c.seq) == (0, 1, 2))
        #expect(a.kind == .move && a.point == .init(x: 10, y: 20) && a.space == .viewport)
        #expect(b.kind == .click && b.zoom == 1.5)
        #expect(c.kind == .type && c.point == nil)
    }

    @Test func leaseActionsMapToLeaseStatesAndEndRestartsSeq() throws {
        var demo = AgentCursorDemo()
        _ = try demo.step(action: "move", session: "demo", target: "tab_1", x: 1, y: 1, tMs: 1)
        #expect(try demo.step(action: "pause", session: "demo", target: "tab_1", x: nil, y: nil, tMs: 2) == .lease(session: "demo", state: .paused))
        #expect(try demo.step(action: "takeover", session: "demo", target: "tab_1", x: nil, y: nil, tMs: 3) == .lease(session: "demo", state: .userDriving))
        #expect(try demo.step(action: "resume", session: "demo", target: "tab_1", x: nil, y: nil, tMs: 4) == .lease(session: "demo", state: .driving))
        #expect(try demo.step(action: "end", session: "demo", target: "tab_1", x: nil, y: nil, tMs: 5) == .lease(session: "demo", state: nil))
        guard case let .input(again) = try demo.step(action: "click", session: "demo", target: "tab_1", x: 1, y: 1, tMs: 6) else {
            Issue.record("expected input")
            return
        }
        #expect(again.seq == 0, "a new lease after end starts at seq 0")
    }

    @Test func badActionsFail() {
        var demo = AgentCursorDemo()
        #expect(throws: AgentCursorDemo.Failure.unknownAction("teleport")) {
            try demo.step(action: "teleport", session: "s", target: "t", x: 1, y: 1, tMs: 0)
        }
        #expect(throws: AgentCursorDemo.Failure.pointRequired("click")) {
            try demo.step(action: "click", session: "s", target: "t", x: nil, y: 5, tMs: 0)
        }
    }

    @Test func theHostListsItsSessions() {
        let host = AgentCursorLayerHost(hostLayer: .init()) { _ in .init(gray: 1, alpha: 1) }
        host.apply(.place(session: "b", point: .zero))
        host.apply(.place(session: "a", point: .zero))
        #expect(host.sessions == ["a", "b"])
    }

    @Test func kindAndPointAreAliasesForActionAndXY() {
        let live = AgentCursorDemo.Request(action: nil, kind: "click", x: nil, y: nil, pointX: 280, pointY: 180)
        #expect(live == AgentCursorDemo.Request(action: "click", kind: nil, x: 280, y: 180, pointX: nil, pointY: nil))
        #expect(live.action == "click" && live.x == 280 && live.y == 180)
        let both = AgentCursorDemo.Request(action: "move", kind: "click", x: 1, y: 2, pointX: 9, pointY: 9)
        #expect(both.action == "move" && both.x == 1 && both.y == 2, "explicit action and x/y win")
        #expect(AgentCursorDemo.Request(action: nil, kind: nil, x: nil, y: nil, pointX: nil, pointY: nil).action == "report")
    }
}
