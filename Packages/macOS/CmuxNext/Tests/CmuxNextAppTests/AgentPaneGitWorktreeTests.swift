@testable import CmuxNextAgentPane
import Foundation
import Testing
import CmuxNextWakeups

/// New Worktree (cx-lyqio.2): a new chat's page asks for a worktree of its folder, and the App
/// runs the session host's `git.worktree.create` there. It needs a real click in the pane, a chat
/// whose repository is this Mac's, and a folder a chat may start in (the check a picked folder gets).
/// Apply (cx-lyqio.4) runs `git.worktree.apply` in the chat's own worktree, on a click, and Remove
/// (cx-lyqio.5) runs `git.worktree.remove` there the same way.
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
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
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

    /// The chat's session lives in a worktree of this Mac.
    private actor WorktreeHost: AgentPaneHostProviding {
        let folder: AgentPaneSessionFolder
        init(_ folder: AgentPaneSessionFolder) { self.folder = folder }
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { sessionId == "s1" ? folder : nil }
    }

    private static let worktreeRoot = "/Users/me/.cmux/worktrees/app/fix-login"

    private static func applyRig(isLocal: Bool = true) -> (AgentPaneModel, Sent) {
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: WorktreeHost(AgentPaneSessionFolder(cwd: worktreeRoot, isLocal: isLocal)), sessionId: "s1")
        model.gitWritesHere = { true }
        let sent = Sent()
        model.onGitWrite = { write, cwd in
            sent.calls.append((write, cwd))
            return Data(#"{"value":{"main_root":"/Users/me/app","files":["a.txt"]},"replayed":false}"#.utf8)
        }
        return (model, sent)
    }

    private static func apply(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "git.worktree.apply", "params": params])
    }

    /// Apply (cx-lyqio.4): a click brings the chat's worktree work to its main checkout. It runs in
    /// the folder of the pane's own session, as the host names it, never a folder the page sends.
    @Test func aClickAppliesTheChatsWorktreeInItsOwnFolder() async throws {
        let (model, sent) = Self.applyRig()
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.apply(["session_id": "s1", "cwd": "/elsewhere", "idempotency_key": "k1"]))
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(sent.calls.count == 1)
        #expect(sent.calls.first?.0.operation == "git.worktree.apply")
        #expect(sent.calls.first?.0.sessionId == "s1")
        #expect(sent.calls.first?.0.key == "k1")
        #expect(sent.calls.first?.1 == Self.worktreeRoot)
    }

    /// Page script alone, a read for another chat, or a chat on another machine applies nothing.
    @Test func applyNeedsAClickThisChatAndThisMac() async throws {
        let (model, sent) = Self.applyRig()
        let unclicked = await model.respond(to: Self.apply(["session_id": "s1", "idempotency_key": "k1"]))
        #expect(unclicked["ok"] as? Bool == false)
        model.transport.gestures.record()
        let other = await model.respond(to: Self.apply(["session_id": "s2", "idempotency_key": "k1"]))
        #expect(other["ok"] as? Bool == false)
        let (remote, remoteSent) = Self.applyRig(isLocal: false)
        remote.transport.gestures.record()
        let away = await remote.respond(to: Self.apply(["session_id": "s1", "idempotency_key": "k1"]))
        #expect(away["ok"] as? Bool == false)
        #expect(sent.calls.isEmpty)
        #expect(remoteSent.calls.isEmpty)
    }

    private static func remove(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "git.worktree.remove", "params": params])
    }

    /// Remove (cx-lyqio.5): a click removes the chat's worktree, in the folder of the pane's own
    /// session. "Remove anyway" carries `discard`, so work found nowhere else goes only when the
    /// user said so.
    @Test func aClickRemovesTheChatsWorktreeAndOnlyDiscardsWhenAsked() async throws {
        let (model, sent) = Self.applyRig()
        let unclicked = await model.respond(to: Self.remove(["session_id": "s1", "idempotency_key": "k1"]))
        #expect(unclicked["ok"] as? Bool == false)
        #expect(sent.calls.isEmpty)
        model.transport.gestures.record()
        let kept = await model.respond(to: Self.remove(["session_id": "s1", "cwd": "/elsewhere", "idempotency_key": "k1"]))
        #expect(kept["ok"] as? Bool == true, "\(kept)")
        model.transport.gestures.record()
        let discarded = await model.respond(to: Self.remove(["session_id": "s1", "idempotency_key": "k2", "discard": true]))
        #expect(discarded["ok"] as? Bool == true, "\(discarded)")
        #expect(sent.calls.count == 2)
        #expect(sent.calls.allSatisfy { $0.0.operation == "git.worktree.remove" && $0.1 == Self.worktreeRoot })
        let keep = AgentPaneGitWrite(method: "git.worktree.remove", params: ["session_id": "s1", "idempotency_key": "k2"])
        let discard = AgentPaneGitWrite(method: "git.worktree.remove", params: ["session_id": "s1", "idempotency_key": "k2", "discard": true])
        #expect(keep != nil && keep != discard)
        #expect(sent.calls.last?.0 == discard)
        // Another chat's read removes nothing.
        model.transport.gestures.record()
        let other = await model.respond(to: Self.remove(["session_id": "s2", "idempotency_key": "k3"]))
        #expect(other["ok"] as? Bool == false)
        #expect(sent.calls.count == 2)
    }
}
