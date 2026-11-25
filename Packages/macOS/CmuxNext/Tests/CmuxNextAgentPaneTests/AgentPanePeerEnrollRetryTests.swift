import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Peer-route approvals in one click (Leo, 2026-11-04: "this is such an awkward flow it doesnt let
/// me trust on click when i try it pops error or something then asks me to \"enroll\"???"). A peer
/// that has not enrolled this Mac refuses the person's signed Allow once: the page never sees that
/// refusal, this Mac enrolls there, and the same signed answer goes again, once. Only an enroll
/// that fails gives the page the refusal, and the notice says why with Enroll this Mac.
@Suite(.serialized)
@MainActor
struct AgentPanePeerEnrollRetryTests {
    typealias Relayed = AgentPaneRelayedAllowTests

    /// A peer chat whose pane can enroll this Mac (`failure`: what the enroll says, nil enrolled).
    private func peerChat(_ server: AcpmuxStandInServer, _ inbox: Relayed.PageInbox, _ transport: AgentPaneTransport,
                          enrolls: @escaping (String) -> String?) async throws -> Int {
        let id = try await Relayed.peerChat(server, inbox, transport)
        let key = try #require(transport.peerApprover?.key)
        transport.peerApprover = AgentPanePeerApprover(key: key) { peer, _ in enrolls(peer) }
        transport.acpmuxSocket = "/tmp/far.sock"
        server.setAnswers(false)
        return id
    }

    /// The signed allow's signature in a sent answer.
    private func approverDecision(_ frame: String) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
        let meta = ((object?["params"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        return (meta?["approverDecision"] as? [String: Any])?["signature"] as? String
    }

    @Test func aRefusalForWantOfEnrollingEnrollsAndSendsTheSameAnswerAgain() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = Relayed.PageInbox()
        let transport = AgentPaneTransport()
        var peerOff: [AgentPanePeerApprovals?] = []
        var enrolled: [String] = []
        transport.onPeerApprovalsOff = { peerOff.append($0) }
        let id = try await peerChat(server, inbox, transport) { enrolled.append($0); return nil }

        transport.gestures.record(click: true)
        let intent = try #require(Relayed.intent(option: "yes"))
        let ticket = try #require(transport.reserveGesture(intent))
        #expect(await transport.send(connection: id, frames: [Relayed.allow(ticket: ticket)]) == nil)
        let first = try await Relayed.relayID(server, "permission_respond", after: 0)
        let firstFrame = try #require(server.peers.first?.frames.last { $0.contains("permission_respond") })
        server.push(Relayed.refusal(first, peer: "far"), to: 0)

        // The click enrolled this Mac there and its answer went again, signed as before.
        let second = try await Relayed.relayID(server, "permission_respond", after: 1)
        #expect(second != first)
        #expect(enrolled == ["far"])
        let secondFrame = try #require(server.peers.first?.frames.last { $0.contains("permission_respond") })
        #expect(approverDecision(secondFrame) != nil)
        #expect(approverDecision(secondFrame) == approverDecision(firstFrame), "the answer was signed anew")
        #expect(peerOff.contains(.enrolling(peer: "far")))
        #expect(!peerOff.contains(.notEnrolled(peer: "far")), "the pane asked to enroll after the click")

        // Its reply is the page's answer; the page never saw the refusal.
        server.push(#"{"jsonrpc":"2.0","id":\#(second),"result":{}}"#, to: 0)
        let reply = await inbox.frame(containing: "\"id\":7")
        #expect(reply.contains("\"result\""), "the page got \(reply)")
        #expect(peerOff.last == .some(nil), "the enrolling notice stayed")
    }

    @Test func anEnrollThatFailsGivesThePageTheRefusalAndSaysWhy() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = Relayed.PageInbox()
        let transport = AgentPaneTransport()
        var peerOff: [AgentPanePeerApprovals?] = []
        transport.onPeerApprovalsOff = { peerOff.append($0) }
        let id = try await peerChat(server, inbox, transport) { _ in "ssh: far: no route" }

        transport.gestures.record(click: true)
        let intent = try #require(Relayed.intent(option: "yes"))
        let ticket = try #require(transport.reserveGesture(intent))
        #expect(await transport.send(connection: id, frames: [Relayed.allow(ticket: ticket)]) == nil)
        let first = try await Relayed.relayID(server, "permission_respond", after: 0)
        server.push(Relayed.refusal(first, peer: "far"), to: 0)

        _ = await inbox.frame(containing: "person_required")
        #expect(server.peers.first?.frames.filter { $0.contains("permission_respond") }.count == 1, "it went again unenrolled")
        #expect(peerOff.last == .some(.enrollFailed(peer: "far", reason: "ssh: far: no route")))
    }

    /// The answer goes again once: a second refusal reaches the page and the notice offers Enroll.
    @Test func theAnswerGoesAgainOnlyOnce() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = Relayed.PageInbox()
        let transport = AgentPaneTransport()
        var peerOff: [AgentPanePeerApprovals?] = []
        var enrolled = 0
        transport.onPeerApprovalsOff = { peerOff.append($0) }
        let id = try await peerChat(server, inbox, transport) { _ in enrolled += 1; return nil }

        transport.gestures.record(click: true)
        let intent = try #require(Relayed.intent(option: "yes"))
        let ticket = try #require(transport.reserveGesture(intent))
        #expect(await transport.send(connection: id, frames: [Relayed.allow(ticket: ticket)]) == nil)
        server.push(Relayed.refusal(try await Relayed.relayID(server, "permission_respond", after: 0), peer: "far"), to: 0)
        server.push(Relayed.refusal(try await Relayed.relayID(server, "permission_respond", after: 1), peer: "far"), to: 0)

        _ = await inbox.frame(containing: "person_required")
        #expect(enrolled == 1)
        #expect(peerOff.last == .some(.notEnrolled(peer: "far")))
    }

    /// The bookkeeping alone: a signed single answer with a frame to send again is held from the
    /// page and read as enroll-then-retry; without one, or once it counted, nothing is held.
    @Test func onlyARetryableSignedRefusalIsHeld() {
        let decisions = AcpmuxDecisionContexts()
        let refusal: (Int) -> [String: Any] = { id in
            ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "approve this on the Mac app",
                                                    "data": ["reason": "permission.person_required", "peer": "far"]]]
        }
        decisions.sent(pageID: "1", proved: true, single: true, retry: "{\"method\":\"_acpmux/permission_respond\"}")
        decisions.sent(pageID: "2", proved: true, single: true)
        decisions.sent(pageID: "3", proved: true, single: true, retry: "{}")
        decisions.sent(pageID: "4", proved: true, single: false, retry: "{}")
        #expect(decisions.observe(refusal(1), replyTo: "_acpmux/permission_respond") == "1")
        #expect(decisions.observe(refusal(2), replyTo: "_acpmux/permission_respond") == nil)
        #expect(decisions.observe(["jsonrpc": "2.0", "id": 3, "result": [String: Any]()], replyTo: "_acpmux/permission_respond") == nil)
        #expect(decisions.observe(refusal(4), replyTo: "_acpmux/permission_group_respond") == nil)
        #expect(decisions.takeAnswers() == [
            .enrollThenRetry(peer: "far", pageID: "1", frame: "{\"method\":\"_acpmux/permission_respond\"}"),
            .refused(peer: "far"), .counted, .refused(peer: "far"),
        ])
    }

    /// The notice while the click enrolls says so with no button; a failed enroll says why and
    /// offers Enroll this Mac.
    @Test func theNoticeSaysEnrollingThenWhatFailed() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "peer-enroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        defer { view.close() }
        view.model.transport.peerApprover = AgentPanePeerApprover(key: AcpmuxMacApprover()) { _, _ in nil }

        view.showPeerApprovalsOff(.enrolling(peer: "far"))
        #expect(view.remoteApprovalsNoticeLines?.lines == [AgentPaneView.peerApprovalsEnrollingTitle("far"),
                                                           AgentPaneView.peerApprovalsEnrollingDetail])
        #expect(view.remoteApprovalsNoticeLines?.restart == false)

        view.showPeerApprovalsOff(.enrollFailed(peer: "far", reason: "ssh: no route"))
        #expect(view.remoteApprovalsNoticeLines?.lines.first == AgentPaneView.peerApprovalsOffTitle("far"))
        #expect(view.remoteApprovalsNoticeLines?.lines.last == AgentPaneView.peerApprovalsEnrollFailed("far", "ssh: no route"))
        #expect(view.remoteApprovalsNoticeLines?.restart == true)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
