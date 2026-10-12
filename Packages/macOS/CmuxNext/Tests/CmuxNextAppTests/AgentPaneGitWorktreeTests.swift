@testable import CmuxNextAgentPane
import Foundation
import Testing

/// New Worktree (cx-lyqio.2): a new chat's page asks for a worktree of its folder, and the App
/// runs the session host's `git.worktree.create` there. It needs a real click in the pane, a chat
/// whose repository is this Mac's, and a folder the pane already has.
@MainActor
struct AgentPaneGitWorktreeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The writes the App was asked to run, with the folder each runs in.
    @MainActor
    private final class Sent {
        var calls: [(AgentPaneGitWrite, String)] = []
    }

    private static let folder = "/Users/me/app"

    private static func rig() -> (AgentPaneModel, Sent) {
        let model = AgentPaneModel(host: NoHost())
        model.workspaceRoots = { [folder] }
        model.gitWritesHere = { true }
        let sent = Sent()
        model.onGitWrite = { write, cwd in
            sent.calls.append((write, cwd))
            return Data(#"{"value":{"root":"/Users/me/.cmux/worktrees/app/fix-login","branch":"cmux/fix-login"},"replayed":false}"#.utf8)
        }
        return (model, sent)
    }

    private static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "git.worktree.create", "params": params])
    }

    @Test func aClickMakesTheWorktreeOfTheChatsFolder() async {
        let (model, sent) = Self.rig()
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.request(["cwd": Self.folder, "name": "fix login", "idempotency_key": "k1"]))
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(sent.calls.count == 1)
        #expect(sent.calls.first?.0 == .worktree(cwd: Self.folder, name: "fix login", key: "k1"))
        #expect(sent.calls.first?.0.operation == "git.worktree.create")
        #expect(sent.calls.first?.1 == Self.folder)
    }

    /// Page script alone makes no worktree.
    @Test func withoutAClickNothingRuns() async {
        let (model, sent) = Self.rig()
        let reply = await model.respond(to: Self.request(["cwd": Self.folder, "idempotency_key": "k1"]))
        #expect(reply["ok"] as? Bool == false)
        #expect(sent.calls.isEmpty)
    }

    /// A folder the pane does not have, or one on another machine, gets no worktree here.
    @Test func aFolderOutsideThePaneOrOnAnotherMachineIsRefused() async {
        let (model, sent) = Self.rig()
        for cwd in ["/Users/me/other", "/", "relative/app", "/Users/me/app\u{0}x"] {
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.request(["cwd": cwd, "idempotency_key": "k1"]))
            #expect(reply["ok"] as? Bool == false, "\(cwd)")
        }
        model.gitWritesHere = { false }
        model.transport.gestures.record()
        let remote = await model.respond(to: Self.request(["cwd": Self.folder, "idempotency_key": "k1"]))
        #expect(remote["ok"] as? Bool == false)
        #expect(sent.calls.isEmpty)
    }
}
