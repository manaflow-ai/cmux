@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A GitHub repository picked for a new chat on this Mac (`github.repos.checkout`): the page's one call finds this
/// Mac's checkout of it or clones it, then makes the chat's worktree of that checkout as New Worktree does. These run
/// real git against a folder of bare repositories that stands in for github.com (`url.<folder>.insteadOf`), so the
/// clone, the remote check and the clean-up are git's own.
@MainActor
struct AgentPaneGitHubCheckoutTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Every git run: its arguments and the environment it was given.
    private actor Runs {
        var all: [(arguments: [String], environment: [String: String])] = []
        func add(_ arguments: [String], _ environment: [String: String]) { all.append((arguments, environment)) }
        var clones: Int { all.filter { $0.arguments.contains("clone") }.count }
    }

    /// The writes the App was asked to run, with the folder each runs in.
    @MainActor private final class Sent { var calls: [(AgentPaneGitWrite, String)] = [] }

    private struct Rig {
        let model: AgentPaneModel
        let sent: Sent
        let runs: Runs
        let root: URL
        let hub: URL
        let scratch: URL
        let checkout: AgentPaneGitHubCheckout
    }

    /// git with none of this Mac's global or system config (signing, url rewrites, templates): the tests' own only.
    static let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

    private static func git(_ arguments: [String]) async throws {
        let run = try #require(await AgentPaneGitHubCheckout.systemGit(
            ["-c", "user.name=cmux test", "-c", "user.email=test@cmux.invalid", "-c", "init.defaultBranch=main"] + arguments,
            nil, hermetic, .seconds(60)))
        #expect(run.status == 0, "git \(arguments)")
    }

    /// `hub/<owner>/<name>.git`, a bare repository with one commit (its README names it).
    private static func publish(_ repo: String, in hub: URL, scratch: URL) async throws {
        let work = scratch.appending(path: "work-\(UUID().uuidString)").path
        let bare = hub.appending(path: repo + ".git").path
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try Data("# \(repo)\n".utf8).write(to: URL(fileURLWithPath: work).appending(path: "README.md"))
        try await git(["init", "--quiet", "--bare", bare])
        try await git(["-C", work, "init", "--quiet"])
        try await git(["-C", work, "add", "README.md"])
        try await git(["-C", work, "commit", "--quiet", "-m", "first"])
        try await git(["-C", work, "push", "--quiet", bare, "HEAD:refs/heads/main"])
    }

    /// Runs on the main actor as a clone starts (the person picking another folder meanwhile).
    @MainActor final class DuringClone { var run: (@MainActor () -> Void)? }

    private static func rig(token: String? = "ghs_test0123", duringClone: DuringClone = DuringClone()) async throws -> Rig {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "gh-checkout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let hub = scratch.appending(path: "hub", directoryHint: .isDirectory)
        let root = scratch.appending(path: "repos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        try await publish("acme/api", in: hub, scratch: scratch)
        let runs = Runs()
        // github.com is the hub folder for these gits: the URL the checkout asks for is GitHub's own.
        let rewrite = ["-c", "url.\(hub.absoluteString).insteadOf=https://github.com/", "-c", "protocol.file.allow=always"]
        let checkout = AgentPaneGitHubCheckout(root: root, token: { _ in token }, git: { arguments, folder, environment, timeout in
            await runs.add(arguments, environment)
            if arguments.contains("clone") { await MainActor.run { duringClone.run?() } }
            return await AgentPaneGitHubCheckout.systemGit(rewrite + arguments, folder, environment.merging(hermetic) { old, _ in old }, timeout)
        })
        let model = AgentPaneModel(host: NoHost())
        model.workspaceRoots = { [] }
        model.gitWritesHere = { true }
        model.gitHub = AgentPaneGitHub(status: { .ready(reposScope: "all") }, connect: { .alreadyConnected },
                                       repos: { _ in .success(.init(repos: [], truncated: false)) }, checkout: checkout)
        let sent = Sent()
        model.onGitWrite = { write, cwd in
            sent.calls.append((write, cwd))
            return Data(#"{"value":{"root":"/Users/me/.cmux/worktrees/api/lane","branch":"cmux/lane"},"replayed":false}"#.utf8)
        }
        return Rig(model: model, sent: sent, runs: runs, root: root, hub: hub, scratch: scratch, checkout: checkout)
    }

    private static func request(_ repo: String, candidates: [String] = [], key: String = "k1") -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "github.repos.checkout",
                                "params": ["repo": repo, "candidates": candidates, "idempotency_key": key]])
    }

    private static func value(_ reply: [String: Any]) -> [String: Any]? { reply["value"] as? [String: Any] }

    @Test func aPickWithNoCheckoutHereClonesItThenMakesTheChatsWorktreeOfTheClone() async throws {
        let rig = try await Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.scratch) }
        rig.model.transport.gestures.record()
        let reply = await rig.model.respond(to: Self.request("acme/api"))
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        let clone = rig.root.appending(path: "acme/api").path
        #expect(Self.value(reply)?["checkout"] as? String == clone)
        #expect(Self.value(reply)?["cloned"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: clone + "/README.md"))
        // The worktree is made of the clone, on the same click, under the page's key.
        #expect(rig.sent.calls.count == 1)
        #expect(rig.sent.calls.first?.0.operation == "git.worktree.create")
        #expect(rig.sent.calls.first?.1 == AcpmuxPathPolicy.canonical(clone))
        // Nothing half-made is left beside it.
        let owner = try FileManager.default.contentsOfDirectory(atPath: rig.root.appending(path: "acme").path)
        #expect(owner == ["api"])
        // The token went to that one git through its environment, never its arguments, and nothing of it stayed.
        let clones = await rig.runs.all.filter { $0.arguments.contains("clone") }
        #expect(clones.count == 1)
        #expect(clones.first?.environment[AgentPaneGitHubCheckout.tokenVariable] == "ghs_test0123")
        #expect(clones.first?.arguments.contains { $0.contains("ghs_test0123") } == false)
        let config = try String(contentsOfFile: clone + "/.git/config", encoding: .utf8)
        #expect(!config.contains("ghs_"))
        #expect(!config.contains("credential"))
        #expect(config.contains("https://github.com/acme/api.git"))
    }

    /// A folder picked while the clone runs wins: the clone finishes (the next pick finds it), but no worktree is made.
    @Test func aFolderPickedDuringTheCloneMakesNoWorktree() async throws {
        let during = DuringClone()
        let rig = try await Self.rig(duringClone: during)
        defer { try? FileManager.default.removeItem(at: rig.scratch) }
        during.run = { _ = rig.model.beginPick() }
        rig.model.transport.gestures.record()
        let reply = await rig.model.respond(to: Self.request("acme/api"))
        #expect(reply["ok"] as? Bool == false)
        #expect(rig.sent.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: rig.root.appending(path: "acme/api/README.md").path))
    }

    @Test func aRepositoryAlreadyHereIsUsedAsItIsWithNoClone() async throws {
        let rig = try await Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.scratch) }
        // A checkout of its own, its origin written as ssh in another case: the page names a folder inside it.
        let mine = rig.scratch.appending(path: "src/api").path
        try await Self.git(["clone", "--quiet", rig.hub.appending(path: "acme/api.git").path, mine])
        try await Self.git(["-C", mine, "remote", "set-url", "origin", "git@github.com:Acme/API.git"])
        try FileManager.default.createDirectory(atPath: mine + "/docs", withIntermediateDirectories: true)
        // Another repository's checkout the page also names is passed over.
        try await Self.publish("acme/web", in: rig.hub, scratch: rig.scratch)
        let other = rig.scratch.appending(path: "src/web").path
        try await Self.git(["clone", "--quiet", rig.hub.appending(path: "acme/web.git").path, other])
        try await Self.git(["-C", other, "remote", "set-url", "origin", "https://github.com/acme/web"])
        rig.model.transport.gestures.record()
        let reply = await rig.model.respond(to: Self.request("acme/api", candidates: [other, mine + "/docs"]))
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        let top = try #require(Self.value(reply)?["checkout"] as? String)
        #expect(AcpmuxPathPolicy.canonical(top) == AcpmuxPathPolicy.canonical(mine))
        #expect(Self.value(reply)?["cloned"] as? Bool == false)
        #expect(await rig.runs.clones == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.root.path))
        #expect(rig.sent.calls.first?.1 == AcpmuxPathPolicy.canonical(mine))
    }

    @Test func theSecondPickFindsTheFirstPicksCloneAndTwoAtOnceShareOne() async throws {
        let rig = try await Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.scratch) }
        let checkout = rig.checkout
        let first = Task { await checkout.checkout(repo: "acme/api", candidates: []) }
        let second = Task { await checkout.checkout(repo: "acme/api", candidates: []) }
        let answers = [await first.value, await second.value]
        #expect(answers.allSatisfy { (try? $0.get().path) == rig.root.appending(path: "acme/api").path })
        #expect(await rig.runs.clones == 1)
        let again = try await rig.checkout.checkout(repo: "acme/api", candidates: []).get()
        #expect(again.cloned == false)
        #expect(await rig.runs.clones == 1)
    }

    @Test func aDefaultFolderSomethingElseHoldsIsLeftAlone() async throws {
        let rig = try await Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.scratch) }
        let taken = rig.root.appending(path: "acme/api")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: taken.appending(path: "notes.txt"))
        let found = try await rig.checkout.checkout(repo: "acme/api", candidates: []).get()
        #expect(found.path == rig.root.appending(path: "acme/api-2").path)
        #expect(found.cloned)
        #expect(try String(contentsOf: taken.appending(path: "notes.txt"), encoding: .utf8) == "mine")
    }

    @Test func aCloneThatFailsWithTheTokenTriesThePersonsOwnGitThenSaysSoAndLeavesNothing() async throws {
        let rig = try await Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.scratch) }
        rig.model.transport.gestures.record()
        let reply = await rig.model.respond(to: Self.request("acme/missing"))
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "github.clone_failed")
        let clones = await rig.runs.all.filter { $0.arguments.contains("clone") }
        #expect(clones.count == 2)
        #expect(clones.last?.environment[AgentPaneGitHubCheckout.tokenVariable] == nil)
        #expect(rig.sent.calls.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: rig.root.appending(path: "acme").path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func withoutATokenThePersonsOwnGitClones() async throws {
        let rig = try await Self.rig(token: nil)
        defer { try? FileManager.default.removeItem(at: rig.scratch) }
        let found = try await rig.checkout.checkout(repo: "acme/api", candidates: []).get()
        #expect(found.cloned)
        let clones = await rig.runs.all.filter { $0.arguments.contains("clone") }
        #expect(clones.count == 1)
        #expect(clones.first?.arguments.contains { $0.hasPrefix("credential.helper") } == false)
    }

    /// Page script alone clones nothing, and neither does a Cloud or SSH chat's pick (its machine clones), nor a
    /// chat that already started.
    @Test func onlyAClickInANewChatOnThisMacClones() async throws {
        let rig = try await Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.scratch) }
        let unclicked = await rig.model.respond(to: Self.request("acme/api"))
        #expect(unclicked["ok"] as? Bool == false)
        rig.model.remoteChat = true
        rig.model.transport.gestures.record()
        let remote = await rig.model.respond(to: Self.request("acme/api"))
        #expect(remote["ok"] as? Bool == false)
        rig.model.remoteChat = false
        rig.model.gitWritesHere = { false }
        rig.model.transport.gestures.record()
        let notHere = await rig.model.respond(to: Self.request("acme/api"))
        #expect(notHere["ok"] as? Bool == false)
        #expect(await rig.runs.all.isEmpty)
        #expect(rig.sent.calls.isEmpty)
    }
}
