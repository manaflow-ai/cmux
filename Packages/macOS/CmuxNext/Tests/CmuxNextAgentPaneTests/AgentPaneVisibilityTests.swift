import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent pane tells acpmux once per hidden or shown edge (`_acpmux/visibility`, p14-energy-118),
/// after the edge's turn and without waiting, so acpmux can freeze a hidden chat's idle harness.
@MainActor
struct AgentPaneVisibilityTests {
    final class Rig {
        var hidden = false
        var target: AgentPaneVisibilityEdges.Target? = .init(connection: 1, session: "s1")
        var accepts = true
        var sent: [(target: AgentPaneVisibilityEdges.Target, visible: Bool)] = []
        var turns: [@MainActor @Sendable () -> Void] = []
        lazy var edges = AgentPaneVisibilityEdges(
            isHidden: { [unowned self] in self.hidden },
            target: { [unowned self] in self.target },
            send: { [unowned self] target, visible in
                guard self.accepts else { return false }
                self.sent.append((target, visible))
                return true
            },
            nextTurn: { [unowned self] work in self.turns.append(work) })

        func runTurns() {
            let pending = turns
            turns = []
            for work in pending { work() }
        }

        func edge(hidden: Bool) {
            self.hidden = hidden
            edges.changed()
            runTurns()
        }
    }

    @Test func hideHideShowSendsTwoMessages() {
        let rig = Rig()
        rig.edge(hidden: true)
        rig.edge(hidden: true)
        rig.edge(hidden: false)
        #expect(rig.sent.map(\.visible) == [false, true])
        #expect(rig.sent.allSatisfy { $0.target == .init(connection: 1, session: "s1") })
    }

    @Test func theReportRunsAfterTheEdgesTurn() {
        let rig = Rig()
        rig.hidden = true
        rig.edges.changed()
        #expect(rig.sent.isEmpty, "the edge's own turn did socket work")
        #expect(rig.turns.count == 1)
        rig.runTurns()
        #expect(rig.sent.map(\.visible) == [false])
    }

    @Test func edgesInOneTurnMakeOneReport() {
        let rig = Rig()
        rig.hidden = true
        rig.edges.changed()
        rig.hidden = false
        rig.edges.changed()
        rig.hidden = true
        rig.edges.changed()
        #expect(rig.turns.count == 1)
        rig.runTurns()
        #expect(rig.sent.map(\.visible) == [false])

        // Hidden and shown again within one turn: acpmux still has it shown, nothing goes.
        let other = Rig()
        other.hidden = true
        other.edges.changed()
        other.hidden = false
        other.edges.changed()
        other.runTurns()
        #expect(other.sent.isEmpty)
    }

    @Test func aShownPaneNeverToldHiddenSendsNothing() {
        let rig = Rig()
        rig.edge(hidden: false)
        rig.edge(hidden: false)
        #expect(rig.sent.isEmpty)
    }

    @Test func noConnectionSendsNothingAndTheNextEdgeReports() {
        let rig = Rig()
        rig.target = nil
        rig.edge(hidden: true)
        #expect(rig.sent.isEmpty)
        rig.target = .init(connection: 2, session: "s1")
        rig.edge(hidden: true)
        #expect(rig.sent.map(\.visible) == [false])
    }

    @Test func aNewConnectionOrSessionIsToldItsHideAgain() {
        let rig = Rig()
        rig.edge(hidden: true)
        rig.target = .init(connection: 2, session: "s1")
        rig.edge(hidden: true)
        rig.target = .init(connection: 2, session: "s2")
        rig.edge(hidden: true)
        rig.edge(hidden: false)
        #expect(rig.sent.map(\.target.connection) == [1, 2, 2, 2])
        #expect(rig.sent.map(\.target.session) == ["s1", "s1", "s2", "s2"])
        #expect(rig.sent.map(\.visible) == [false, false, false, true])
    }

    @Test func aRefusedSendIsToldAgainOnTheNextEdge() {
        let rig = Rig()
        rig.accepts = false
        rig.edge(hidden: true)
        #expect(rig.sent.isEmpty)
        rig.accepts = true
        rig.edge(hidden: true)
        #expect(rig.sent.map(\.visible) == [false])
    }

    @Test func theFrameIsANotificationNamingTheSession() throws {
        let text = try #require(AcpmuxPaneSocket.visibilityFrame(session: "s1", visible: false))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["id"] == nil, "a request would take the person proof's place: \(text)")
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["method"] as? String == "_acpmux/visibility")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "s1")
        #expect(params["visible"] as? Bool == false)
    }

    /// A wire that records what the socket hands it.
    nonisolated final class Wire: AcpmuxPaneWire, @unchecked Sendable { // crash-allow: test support; every access holds the lock
        private let state = Mutex<[String]>([])
        var sent: [String] { state.withLock { $0 } }
        func open(onFrame: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Int, String) -> Void) async throws {}
        func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) {
            state.withLock { $0.append(text) }
            completion(true)
        }
        func cancel(code: Int, reason: String) {}
    }

    @Test func theSocketHandsTheFrameOverWithoutWaiting() async throws {
        let wire = Wire()
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(
            request: URLRequest(url: URL(string: "ws://127.0.0.1")!), wire: wire, limits: transport.limits,
            options: transport.permissionOptions, sessions: transport.sessions, ids: AcpmuxRequestIds(), signal: {})
        try await socket.start(timeout: 1)
        let frame = try #require(AcpmuxPaneSocket.visibilityFrame(session: "s1", visible: true))
        #expect(socket.sendVisibility(session: "s1", visible: true) == nil)
        #expect(wire.sent == [frame])
        socket.close(code: 1000, reason: "", error: nil)
        #expect(socket.sendVisibility(session: "s1", visible: false) == .closed)
    }
}
