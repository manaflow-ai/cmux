import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-fcaq's "Approve its requests in that app" line says where to approve, so it shows only on
/// another install's daemon while the shown chat has a request waiting; a chat with nothing to
/// approve has no floating line over its transcript (Leo, 2026-11-01: "yuck more garbage"). A
/// waiting request is any of them: a tool permission (Bash, Edit), a question or a group member.
struct AgentPaneOtherInstallNoticeTests {
    private static let nonce = String(repeating: "a", count: 64)
    private static let instance = String(repeating: "c", count: 32)

    @Test func showsOnlyOnAnotherInstallWithARequestWaiting() {
        #expect(AgentPaneView.showsOtherInstallNotice(otherInstall: true, requestWaiting: true))
        #expect(!AgentPaneView.showsOtherInstallNotice(otherInstall: true, requestWaiting: false))
        #expect(!AgentPaneView.showsOtherInstallNotice(otherInstall: false, requestWaiting: true))
        #expect(!AgentPaneView.showsOtherInstallNotice(otherInstall: false, requestWaiting: false))
    }

    @Test func aPendingToolPermissionCountsAsWaitingAndItsDecisionClearsIt() {
        let contexts = AcpmuxDecisionContexts()
        #expect(!contexts.hasPending(session: "s"))
        let before = contexts.pendingVersion()
        let params: [String: Any] = [
            "sessionId": "s", "permissionId": "bash-1", "decisionNonce": Self.nonce, "personInstance": Self.instance,
            "request": ["options": [["optionId": "yes", "kind": "allow_once"]],
                        "toolCall": ["toolCallId": "t1", "title": "Bash: ls"]],
        ]
        contexts.observe(["method": "_acpmux/permission_pending", "params": params], replyTo: nil)
        // A tool permission is no question, yet the chat has a request waiting.
        #expect(contexts.questions(session: "s").isEmpty)
        #expect(contexts.hasPending(session: "s"))
        #expect(!contexts.hasPending(session: "other"))
        #expect(contexts.pendingVersion() != before)
        let pendingVersion = contexts.pendingVersion()
        contexts.observe(["method": "_acpmux/event", "params": [
            "dir": "mux", "kind": "permission_decision", "sessionId": "s", "seq": 9, "msg": ["permissionId": "bash-1"],
        ]], replyTo: nil)
        #expect(!contexts.hasPending(session: "s"))
        #expect(contexts.pendingVersion() != pendingVersion)
    }

    @Test func aPendingGroupMemberCountsAsWaiting() {
        let contexts = AcpmuxDecisionContexts()
        let group: [String: Any] = [
            "sessionId": "s", "groupId": "g1", "revision": 1, "state": "pending",
            "items": [["permissionId": "edit-1", "state": "pending",
                       "request": ["options": [["optionId": "yes", "kind": "allow_once"]]]]],
        ]
        contexts.observe(["result": ["groups": [group]]], replyTo: "_acpmux/permission_groups")
        #expect(contexts.hasPending(session: "s"))
        var done = group
        done["revision"] = 2
        done["state"] = "decided"
        contexts.observe(["result": ["groups": [done]]], replyTo: "_acpmux/permission_groups")
        #expect(!contexts.hasPending(session: "s"))
    }
}
