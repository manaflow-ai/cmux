import Foundation
import Testing
@testable import CmuxNextAgentPane

/// RFD 0191 steps 3 and 4: the pane's permission and session maps drop each entry on its own end
/// event (never by size), and a page frame is parsed once on the send path.
struct AcpmuxPaneSettleMapsTests {
    private static func request(_ permission: String, question: Bool = false) -> [String: Any] {
        var request: [String: Any] = ["options": [["optionId": "yes", "kind": "allow_once"],
                                                  ["optionId": "no", "kind": "reject_once"]]]
        if question {
            request["toolCall"] = ["_meta": ["acpmux": ["question": ["items": [["id": "q1", "prompt": "Which?"]]]]]]
        }
        return ["kind": "permission_request", "dir": "mux", "msg": ["permissionId": permission, "request": request]]
    }

    private static func decision(_ permission: String) -> [String: Any] {
        ["kind": "permission_decision", "dir": "mux", "msg": ["permissionId": permission, "outcome": "selected"]]
    }

    private static func event(_ record: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "method": "_acpmux/event", "params": record]
    }

    /// Asks and settles `count` permissions one event at a time; returns what the maps hold.
    private static func settle(_ count: Int, options: AcpmuxPermissionOptions) -> (denies: Int, questions: Int) {
        for index in 0..<count {
            options.observe(event(request("p\(index)", question: index.isMultiple(of: 2))), replyTo: nil)
            options.observe(event(decision("p\(index)")), replyTo: nil)
        }
        return options.heldCount
    }

    @Test func settledPermissionsLeaveBothMaps() {
        let options = AcpmuxPermissionOptions()
        let held = Self.settle(200, options: options)
        #expect(held.denies == 0 && held.questions == 0)
        #expect(!options.isDeny(permissionId: "p0", optionId: "no"))
        #expect(options.questionKeys(permissionId: "p0") == nil)
    }

    @Test func unsettledDenyStillReadsAsDeny() {
        let options = AcpmuxPermissionOptions()
        _ = Self.settle(50, options: options)
        options.observe(Self.event(Self.request("open", question: true)), replyTo: nil)
        #expect(options.isDeny(permissionId: "open", optionId: "no"))
        #expect(options.isKnownAllow(permissionId: "open", optionId: "yes"))
        #expect(options.questionKeys(permissionId: "open") == ["q1", "Which?"])
        #expect(options.heldCount.denies == 1)
    }

    /// History replays in order: a request after its settle (asked again) is kept, one before it is not.
    @Test func historyAppliesInOrder() {
        let options = AcpmuxPermissionOptions()
        let events: [Any] = [Self.request("a"), Self.decision("a"), Self.request("b"), Self.decision("b"), Self.request("b")]
        options.observe(["jsonrpc": "2.0", "id": 1, "result": ["events": events]], replyTo: "_acpmux/attach")
        #expect(!options.isDeny(permissionId: "a", optionId: "no"))
        #expect(options.isDeny(permissionId: "b", optionId: "no"))
        #expect(options.heldCount.denies == 1)
    }

    /// Only the daemon's own record settles: a decision the agent side wrote is no settle.
    @Test func onlyMuxRecordsSettle() {
        let options = AcpmuxPermissionOptions()
        options.observe(Self.event(Self.request("p")), replyTo: nil)
        var forged = Self.decision("p")
        forged["dir"] = "agent"
        options.observe(Self.event(forged), replyTo: nil)
        #expect(options.isDeny(permissionId: "p", optionId: "no"))
    }

    @Test func errorReplyEndsTheWait() {
        let sessions = AcpmuxPaneSessions()
        sessions.sent(method: "session/new", id: "7")
        sessions.sent(method: "_acpmux/handoff_get", id: "8")
        #expect(sessions.awaitingCount.awaiting == 1 && sessions.awaitingCount.handoffs == 1)
        sessions.observe(#"{"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"no"}}"#)
        sessions.observe(["jsonrpc": "2.0", "id": 8, "error": ["code": -32000, "message": "no"]])
        #expect(sessions.awaitingCount.awaiting == 0 && sessions.awaitingCount.handoffs == 0)
        #expect(sessions.isUnstarted)
    }

    /// Bench: the maps at 10x sessions and permissions stay flat (0 held after each ends).
    @Test func mapsStayFlatAtTenTimes() {
        for scale in [100, 1000] {
            let options = AcpmuxPermissionOptions()
            let held = Self.settle(scale, options: options)
            let sessions = AcpmuxPaneSessions()
            for index in 0..<scale {
                sessions.sent(method: "session/new", id: "\(2 * index)")
                sessions.sent(method: "_acpmux/handoff_get", id: "\(2 * index + 1)")
                sessions.observe(["jsonrpc": "2.0", "id": 2 * index, "result": ["sessionId": "s\(index)"]])
                sessions.observe(["jsonrpc": "2.0", "id": 2 * index + 1, "error": ["code": -1, "message": "gone"]])
            }
            print("settle-maps bench scale=\(scale) denies=\(held.denies) questions=\(held.questions) awaiting=\(sessions.awaitingCount)")
            #expect(held.denies == 0 && held.questions == 0)
            #expect(sessions.awaitingCount.awaiting == 0 && sessions.awaitingCount.handoffs == 0)
        }
    }

    /// Step 4: the send path reads and rewrites the parsed frame in place; the box parses no text.
    @Test func sendPathParsesOncePerFrame() {
        let frame: [String: Any] = [
            "jsonrpc": "2.0", "id": 3, "method": "session/permission_respond",
            "params": ["sessionId": "s", "permissionId": "p", "optionId": "yes", "revision": 4,
                       "answers": ["q1": "A"], "annotations": NSNull()],
        ]
        let box = AgentPaneTransport.FrameBox(frame)
        let annotationsIsNil = box.withParam("annotations", { $0 == nil })
        let revision = box.withParam("revision", { ($0 as? NSNumber)?.uint64Value })
        let answer = box.withParam("answers", { value in (value as? [String: String])?["q1"] })
        #expect(annotationsIsNil)
        #expect(revision == 4)
        #expect(answer == "A")
        let promptId = box.withFrame { object -> String? in
            guard var params = object["params"] as? [String: Any] else { return nil }
            params["_meta"] = ["acpmux": ["promptId": "pid"]]
            object["params"] = params
            return "pid"
        }
        #expect(promptId == "pid")
        #expect(box.hasAcpmuxMeta("promptId"))
        #expect(box.encoded(id: nil) != nil)
        #expect(box.parseCount == 0)
        // The path check's rewrite is the one place the box parses text again.
        #expect(box.replace(withJSON: #"{"jsonrpc":"2.0","method":"x","params":{}}"#))
        #expect(box.parseCount == 1)
    }
}
