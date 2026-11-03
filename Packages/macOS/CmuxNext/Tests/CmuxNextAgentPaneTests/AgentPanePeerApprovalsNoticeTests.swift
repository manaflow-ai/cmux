import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Peer-route approvals: the pane's notice when a peer of this Mac's daemon did not count this
/// Mac's allow (``AgentPaneView/showPeerApprovalsOff(_:)``). A new reason replaces the notice,
/// the same one keeps it, a later answer that counted (nil) removes it; Enroll this Mac hides it
/// once enrolled and says what failed otherwise; closing the pane takes it away.
@Suite(.serialized)
@MainActor
struct AgentPanePeerApprovalsNoticeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func pane() throws -> (AgentPaneView, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "peer-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        return (view, directory)
    }

    /// Runs the main actor's queued work until `done` holds (the button's enroll task).
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<50 where !done() { await Task.yield() }
    }

    @Test func aNewReasonReplacesTheNoticeAndACountedAnswerRemovesIt() throws {
        let (view, directory) = try pane()
        defer { view.close(); try? FileManager.default.removeItem(at: directory) }
        view.model.transport.peerApprover = AgentPanePeerApprover(key: AcpmuxMacApprover()) { _, _ in nil }

        view.showPeerApprovalsOff(.onceOnly)
        #expect(view.remoteApprovalsNoticeLines?.lines == [AgentPaneView.peerApprovalsOnceOnly])
        #expect(view.remoteApprovalsNoticeLines?.restart == false)

        // A peer then refuses for want of enrolling: the enroll notice replaces it.
        view.showPeerApprovalsOff(.notEnrolled(peer: "far"))
        #expect(view.remoteApprovalsNoticeLines?.lines.first == AgentPaneView.peerApprovalsOffTitle("far"))
        #expect(view.remoteApprovalsNoticeLines?.restart == true)
        let shown = view.remoteApprovalsNotice
        view.showPeerApprovalsOff(.notEnrolled(peer: "far"))
        #expect(view.remoteApprovalsNotice === shown, "the same reason built a new notice")

        // An answer that counted: the notice goes.
        view.showPeerApprovalsOff(nil)
        #expect(view.remoteApprovalsNotice == nil)
    }

    @Test func enrollHidesTheNoticeOnceEnrolledAndSaysWhatFailedOtherwise() async throws {
        let (view, directory) = try pane()
        defer { view.close(); try? FileManager.default.removeItem(at: directory) }
        var asked: [String] = []
        var through: [[String: String]] = []
        var failure: String? = "ssh: far: no route"
        view.model.transport.peerApprover = AgentPanePeerApprover(key: AcpmuxMacApprover()) { peer, daemon in asked.append(peer); through.append(daemon); return failure }

        // A pane with no daemon enrolls nowhere.
        view.showPeerApprovalsOff(.notEnrolled(peer: "far"))
        #expect(view.pressRemoteApprovalsRestart())
        await settle { false }
        #expect(asked.isEmpty)

        // The daemon the pane talks to when the person clicks, though it reconnects elsewhere
        // while the command runs.
        view.model.transport.acpmuxSocket = "/tmp/far-a.sock"
        #expect(view.pressRemoteApprovalsRestart())
        view.model.transport.acpmuxSocket = "/tmp/far-b.sock"
        await settle { view.remoteApprovalsNoticeLines?.restart == true }
        #expect(asked == ["far"])
        #expect(through == [["ACPMUX_SOCKET": "/tmp/far-a.sock"]])
        #expect(view.remoteApprovalsNoticeLines?.lines.last == AgentPaneView.peerApprovalsEnrollFailed("far", "ssh: far: no route"))
        #expect(view.remoteApprovalsNoticeLines?.restart == true, "the button stayed off after a failure")

        failure = nil
        #expect(view.pressRemoteApprovalsRestart())
        await settle { view.remoteApprovalsNotice == nil }
        #expect(asked == ["far", "far"])
        #expect(view.remoteApprovalsNotice == nil)
    }

    /// The notice takes space in the page's flow (its notice slot above the composer): the pane
    /// adds no view of its own for it, which floated over the transcript's first message (Leo,
    /// 2026-11-01: "yuck more garbage"). A reloaded page gets it again with the pane's other state.
    @Test func theNoticeIsThePagesNotAViewOverTheTranscript() throws {
        let (view, directory) = try pane()
        defer { view.close(); try? FileManager.default.removeItem(at: directory) }
        let before = view.subviews.map(ObjectIdentifier.init)
        view.showPeerApprovalsOff(.onceOnly)
        view.showOtherInstallNotice(true)
        #expect(view.subviews.map(ObjectIdentifier.init) == before, "the notice laid a view over the page")
        let event = try #require(AgentPanePageHost.currentEvents(view).first { $0.kind == "paneNotices" })
        #expect(event == AgentPaneNotice.event(view.paneNotices))
        guard case .array(let notices) = event.value else { Issue.record("not a list"); return }
        #expect(notices.compactMap { $0["title"]?.stringValue } == [AgentPaneView.peerApprovalsOnceOnly])
        // A notice that hides leaves the page an empty list.
        view.showPeerApprovalsOff(nil)
        #expect(AgentPanePageHost.currentEvents(view).first { $0.kind == "paneNotices" }?.value == .array([]))
    }

    /// The page's button (`pane.noticeAction {id}`) runs the notice's action, only on the person's click.
    @Test func thePagesButtonRunsTheNoticesAction() async throws {
        let (view, directory) = try pane()
        defer { view.close(); try? FileManager.default.removeItem(at: directory) }
        var asked: [String] = []
        view.model.transport.peerApprover = AgentPanePeerApprover(key: AcpmuxMacApprover()) { peer, _ in asked.append(peer); return nil }
        view.model.transport.acpmuxSocket = "/tmp/far-a.sock"
        view.showPeerApprovalsOff(.notEnrolled(peer: "far"))
        #expect(AgentPaneRequest(body: ["method": "pane.noticeAction", "params": ["id": "remoteApprovals"]]) == .paneNoticeAction(id: "remoteApprovals"))
        let refused = view.model.paneNoticeAction("remoteApprovals", userGesture: false)
        #expect(refused["ok"] as? Bool != true, "a page script ran the notice's action")
        let reply = view.model.paneNoticeAction("remoteApprovals", userGesture: true)
        #expect(reply["ok"] as? Bool == true)
        await settle { view.remoteApprovalsNotice == nil }
        #expect(asked == ["far"])
        #expect(view.model.paneNoticeAction("remoteApprovals", userGesture: true)["ok"] as? Bool != true)
    }

    @Test func closingThePaneTakesTheNoticeAway() throws {
        let (view, directory) = try pane()
        defer { try? FileManager.default.removeItem(at: directory) }
        view.showPeerApprovalsOff(.onceOnly)
        #expect(view.remoteApprovalsNotice != nil)
        view.close()
        #expect(view.remoteApprovalsNotice == nil)
        #expect(view.peerApprovalsReason == nil)
    }

    /// A reply is read only against an answer this connection sent: after a reconnect (`reset`), a
    /// late reply of the connection before says nothing, so it cannot take the new notice away.
    @Test func aLateReplyFromTheConnectionBeforeSaysNothing() {
        let decisions = AcpmuxDecisionContexts()
        decisions.sent(pageID: "7", proved: true)
        decisions.reset()
        decisions.observe(["jsonrpc": "2.0", "id": 7, "result": [String: Any]()], replyTo: "_acpmux/permission_respond")
        decisions.observe(["jsonrpc": "2.0", "id": 8, "result": [String: Any]()], replyTo: "_acpmux/permission_group_respond")
        #expect(decisions.takeAnswers().isEmpty)
        // An answer this connection sent is read.
        decisions.sent(pageID: "9", proved: false)
        decisions.observe(["jsonrpc": "2.0", "id": 9, "result": [String: Any]()], replyTo: "_acpmux/permission_respond")
        #expect(decisions.takeAnswers() == [.counted])
    }

    /// Enroll runs against the daemon this app registered its key with on the pane's socket (a
    /// DEV or tagged build's own acpmux home), not the default one.
    @Test func enrollGoesToTheDaemonThePaneTalksTo() {
        let approver = AgentPanePeerApprover(key: AcpmuxMacApprover())
        approver.daemons["/tmp/a.sock"] = ["ACPMUX_HOME": "/tmp/a", "ACPMUX_SOCKET": "/tmp/a.sock"]
        #expect(approver.daemon(socket: "/tmp/a.sock") == ["ACPMUX_HOME": "/tmp/a", "ACPMUX_SOCKET": "/tmp/a.sock"])
        #expect(approver.daemon(socket: "/tmp/b.sock") == ["ACPMUX_SOCKET": "/tmp/b.sock"])
        #expect(approver.daemon(socket: nil).isEmpty)
    }
}
