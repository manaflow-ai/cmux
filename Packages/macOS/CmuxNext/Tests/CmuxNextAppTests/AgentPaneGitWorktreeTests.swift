@testable import CmuxNextAgentPane
import Foundation
import Testing

/// New Worktree (cx-lyqio.2): a new chat's page asks for a worktree of its folder, and the App
/// runs the session host's `git.worktree.create` there. It needs a real click in the pane, a chat
/// whose repository is this Mac's, and a folder a chat may start in (the check a picked folder gets).
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

    /// A real project folder, as a chat's folder is: the check a picked folder gets resolves it.
    private static func rig() throws -> (AgentPaneModel, Sent, String) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "git-worktree-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let model = AgentPaneModel(host: NoHost())
        model.workspaceRoots = { [folder] }
        model.gitWritesHere = { true }
        let sent = Sent()
        model.onGitWrite = { write, cwd in
            sent.calls.append((write, cwd))
            return Data(#"{"value":{"root":"/Users/me/.cmux/worktrees/app/fix-login","branch":"cmux/fix-login"},"replayed":false}"#.utf8)
        }
        return (model, sent, folder)
    }

    private static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "git.worktree.create", "params": params])
    }

    @Test func aClickMakesTheWorktreeOfTheChatsFolder() async throws {
        let (model, sent, folder) = try Self.rig()
        let canonical = try #require(AcpmuxPathPolicy.canonical(folder))
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.request(["cwd": folder, "name": "fix login", "idempotency_key": "k1"]))
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(sent.calls.count == 1)
        #expect(sent.calls.first?.0 == .worktree(cwd: canonical, name: "fix login", key: "k1"))
        #expect(sent.calls.first?.0.operation == "git.worktree.create")
        #expect(sent.calls.first?.1 == canonical)
    }

    /// A folder picked from the menu (no root of the workspace) or reached through a symlink is
    /// a chat folder too: the worktree is made of the folder it names.
    @Test func aPickedOrLinkedFolderGetsItsWorktree() async throws {
        let (model, sent, folder) = try Self.rig()
        model.workspaceRoots = { [] }
        let link = folder + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: folder)
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.request(["cwd": link + "/", "idempotency_key": "k1"]))
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(sent.calls.first?.1 == AcpmuxPathPolicy.canonical(folder))
    }

    /// Page script alone makes no worktree.
    @Test func withoutAClickNothingRuns() async throws {
        let (model, sent, folder) = try Self.rig()
        let reply = await model.respond(to: Self.request(["cwd": folder, "idempotency_key": "k1"]))
        #expect(reply["ok"] as? Bool == false)
        #expect(sent.calls.isEmpty)
    }

    /// No folder, the home folder or one above it, or a folder on another machine gets no
    /// worktree here.
    @Test func homeMissingOrRemoteFoldersAreRefused() async throws {
        let (model, sent, folder) = try Self.rig()
        let home = try #require(model.transport.homeFolder)
        for cwd in [folder + "-missing", "/", home, "relative/app", folder + "\u{0}x"] {
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.request(["cwd": cwd, "idempotency_key": "k1"]))
            #expect(reply["ok"] as? Bool == false, "\(cwd)")
        }
        model.gitWritesHere = { false }
        model.transport.gestures.record()
        let remote = await model.respond(to: Self.request(["cwd": folder, "idempotency_key": "k1"]))
        #expect(remote["ok"] as? Bool == false)
        #expect(sent.calls.isEmpty)
    }
}
