@testable import CmuxNextCloud
import Foundation
import Testing

/// A Cloud chat's model credential is sent with its start and held in memory only by the machine's acpmux, so a machine
/// update or crash that restarted it left a sleeping Claude chat "Not logged in" (cmux#57192). Each connect to the
/// machine's daemon sends every chat started there its credential again (``CloudAgentCredentials/connected(machine:)``).
@MainActor
@Suite
struct CloudAgentCredentialRedeliveryTests {
    /// One chat's received pushes on its machine.
    final class Chat: @unchecked Sendable {
        private let lock = NSLock()
        private var got: [[String: String]] = []
        private var reply: CloudAgentCredentialRefresher.PushOutcome = .delivered
        var pushes: [[String: String]] { lock.withLock { got } }
        var answer: CloudAgentCredentialRefresher.PushOutcome {
            get { lock.withLock { reply } }
            set { lock.withLock { reply = newValue } }
        }
        var push: CloudAgentCredentialRefresher.Push { { [self] env in lock.withLock { got.append(env); return reply } } }
    }

    private static func claude(_ id: String, token: String) -> Data {
        Data(#"{"family":"claude","kind":"claude-token","env":{"CLAUDE_CODE_OAUTH_TOKEN":"\#(token)"}}"#.utf8)
    }

    private static func credential(_ id: String) -> CloudAgentCredential {
        CloudAgentCredential(connectionID: id, family: "claude", kind: "claude-token", env: ["CLAUDE_CODE_OAUTH_TOKEN": "start"], expiresAt: nil)
    }

    @Test func aReconnectSendsEachChatItsCredentialAgainWithOneReadPerConnection() async {
        var reads: [String] = []
        let credentials = CloudAgentCredentials { id in reads.append(id); return Self.claude(id, token: "now") }
        let (first, second, other) = (Chat(), Chat(), Chat())
        credentials.started(chat: "a", machine: "vm-1", on: Self.credential("conn-1"), push: first.push)
        credentials.started(chat: "b", machine: "vm-1", on: Self.credential("conn-1"), push: second.push)
        credentials.started(chat: "c", machine: "vm-2", on: Self.credential("conn-2"), push: other.push)
        #expect(first.pushes.isEmpty, "a start sends its credential itself")

        await credentials.connected(machine: "vm-1")
        #expect(first.pushes == [["CLAUDE_CODE_OAUTH_TOKEN": "now"]])
        #expect(second.pushes == [["CLAUDE_CODE_OAUTH_TOKEN": "now"]])
        #expect(other.pushes.isEmpty, "only the machine that connected")
        #expect(reads == ["conn-1"])
    }

    @Test func aChatGoneFromTheMachineIsDroppedAndAnUnreadableConnectionWaits() async {
        var fails = true
        let credentials = CloudAgentCredentials { id in
            if fails { throw CloudAgentCredentials.Failure.unavailable(connection: id) }
            return Self.claude(id, token: "now")
        }
        let (gone, stays) = (Chat(), Chat())
        credentials.started(chat: "a", machine: "vm-1", on: Self.credential("conn-1"), push: gone.push)
        credentials.started(chat: "b", machine: "vm-1", on: Self.credential("conn-1"), push: stays.push)

        await credentials.connected(machine: "vm-1")
        #expect(gone.pushes.isEmpty && stays.pushes.isEmpty, "nothing to send while the Mac's acpmux cannot read it")
        #expect(credentials.heldCount(machine: "vm-1") == 2)

        fails = false
        gone.answer = .gone
        await credentials.connected(machine: "vm-1")
        #expect(credentials.heldCount(machine: "vm-1") == 1)
        await credentials.connected(machine: "vm-1")
        #expect(gone.pushes.count == 1)
        #expect(stays.pushes.count == 2)
    }

    @Test func aForgottenMachineGetsNothing() async {
        let credentials = CloudAgentCredentials { id in Self.claude(id, token: "now") }
        let chat = Chat()
        credentials.started(chat: "a", machine: "vm-1", on: Self.credential("conn-1"), push: chat.push)
        credentials.forget(machine: "vm-1")
        await credentials.connected(machine: "vm-1")
        #expect(chat.pushes.isEmpty)
    }
}
