import CmuxNextCloud
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat on This Mac in a GitHub repository picked from the folder menu (`github:owner/name`): it starts in the
/// repository's clone in `~/cmux/repos` (``AgentPaneLocalRepositories``), made once, started at the pick
/// (`github.repos.prepare`) and awaited by the `session/new` that names it. Before, the pick moved the chat to Cloud,
/// and a chat here in a repository was refused.
struct AgentPaneLocalRepositoryTests {
    /// A clone that counts its runs and answers when the test lets it.
    private actor Clones {
        var runs: [String] = []
        var failNext: CloudMoveCLI.StartChatRepoRefusal?
        private var gate: CheckedContinuation<Void, Never>?
        private var held = false

        func hold() { held = true }
        func release() { held = false; gate?.resume(); gate = nil }
        func failing(_ refusal: CloudMoveCLI.StartChatRepoRefusal) { failNext = refusal }

        func clone(_ repository: String) async throws -> String {
            runs.append(repository)
            if held { await withCheckedContinuation { gate = $0 } }
            if let refusal = failNext { failNext = nil; throw refusal }
            return "/tmp/cmux/repos/github.com/\(repository)"
        }
    }

    private static func repositories(_ clones: Clones, exists: @escaping @Sendable (String) -> Bool = { _ in true }) -> AgentPaneLocalRepositories {
        AgentPaneLocalRepositories(clone: { try await clones.clone($0) }, exists: exists)
    }

    private static func sessionNew(_ cwd: String, peer: String? = nil) throws -> String {
        var params: [String: Any] = ["cwd": cwd, "mcpServers": []]
        if let peer { params["_meta"] = ["acpmux": ["peer": peer]] }
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "session/new", "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    private static func cwd(of text: String) -> String? {
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return (object?["params"] as? [String: Any])?["cwd"] as? String
    }

    @Test func aChatHereInARepositoryStartsInItsClone() async throws {
        let clones = Clones()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-local-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repositories = AgentPaneLocalRepositories(clone: { _ in _ = try await clones.clone("acme/api"); return folder.path })
        let scope = AcpmuxPathPolicy.Scope(roots: [], localRepositories: repositories)
        guard case .success(let checked) = await AcpmuxPathPolicy.check(try Self.sessionNew("github:acme/api"), scope: scope) else {
            Issue.record("a chat here in a repository was refused")
            return
        }
        // The clone's folder, canonical as every folder the daemon gets: the chat starts there.
        #expect(Self.cwd(of: checked.text) == AcpmuxPathPolicy.canonical(folder.path))
        #expect(await clones.runs == ["acme/api"])
    }

    @Test func thePickAndTheStartShareOneClone() async throws {
        let clones = Clones()
        await clones.hold()
        let repositories = Self.repositories(clones)
        // The pick starts the clone; the Send that follows while it runs waits for the same one.
        async let picked = repositories.folder("acme/api")
        async let sent = repositories.folder("Acme/API")
        while await clones.runs.isEmpty { await Task.yield() }
        await clones.release()
        #expect(try await picked == "/tmp/cmux/repos/github.com/acme/api")
        #expect(try await sent == "/tmp/cmux/repos/github.com/acme/api")
        // A later chat in it gets the folder with no clone at all.
        #expect(try await repositories.folder("acme/api") == "/tmp/cmux/repos/github.com/acme/api")
        #expect(await clones.runs == ["acme/api"])
    }

    @Test func aFolderRemovedSinceIsClonedAgain() async throws {
        let clones = Clones()
        let repositories = Self.repositories(clones, exists: { _ in false })
        _ = try await repositories.folder("acme/api")
        _ = try await repositories.folder("acme/api")
        #expect(await clones.runs == ["acme/api", "acme/api"])
    }

    @Test func aFailedCloneSaysWhyAndTheNextTryClonesAgain() async throws {
        let clones = Clones()
        await clones.failing(.init(code: "repo.clone_failed", message: "git clone https://github.com/acme/api failed: Repository not found."))
        let scope = AcpmuxPathPolicy.Scope(roots: [], localRepositories: Self.repositories(clones))
        guard case .failure(let refusal) = await AcpmuxPathPolicy.check(try Self.sessionNew("github:acme/api"), scope: scope) else {
            Issue.record("a failed clone started a chat")
            return
        }
        #expect(refusal.error == .pathInvalid)
        #expect(refusal.method == "session/new")
        #expect(refusal.reason == "repo.clone_failed")
        let message = refusal.message ?? ""
        #expect(message.contains("Repository not found"))
        // Not remembered: the next start (or pick) clones again.
        _ = try await scope.localRepositories?.folder("acme/api")
        #expect(await clones.runs == ["acme/api", "acme/api"])
    }

    @Test func aStartOnAnotherComputerIsStillRefusedAndClonesNothingHere() async throws {
        let clones = Clones()
        let scope = AcpmuxPathPolicy.Scope(roots: ["/tmp"], localRepositories: Self.repositories(clones))
        guard case .failure(let refusal) = await AcpmuxPathPolicy.check(try Self.sessionNew("github:acme/api", peer: "studio"), scope: scope) else {
            Issue.record("a peer start in a repository went with a github: folder")
            return
        }
        #expect(refusal.error == .pathInvalid)
        #expect(await clones.runs.isEmpty)
    }

    @Test func aPaneWithNoClonesKeepsTheCloudOnlyRefusal() async throws {
        guard case .failure(let refusal) = await AcpmuxPathPolicy.check(try Self.sessionNew("github:acme/api"), scope: AcpmuxPathPolicy.Scope(roots: ["/tmp"])) else {
            Issue.record("a chat here in a repository started with no clones")
            return
        }
        #expect(refusal.reason == AgentPaneGitHubFolder.cloudOnlyReason)
    }

    @MainActor @Test func prepareAnswersTheClonesFolder() async throws {
        let clones = Clones()
        let gitHub = AgentPaneGitHub(status: { .ready(reposScope: "all") },
                                     connect: { .alreadyConnected }, repos: { _ in .failure(.unavailable) },
                                     local: Self.repositories(clones))
        let request = try #require(AgentPaneGitHubRequest(method: "github.repos.prepare", params: ["cwd": "github:acme/api"]))
        let reply = await request.reply(gitHub) { false }
        #expect(reply["ok"] as? Bool == true)
        let dir = (reply["value"] as? [String: Any])?["dir"] as? String
        #expect(dir == "/tmp/cmux/repos/github.com/acme/api")
        // Only a repository folder: anything else is no request.
        #expect(AgentPaneGitHubRequest(method: "github.repos.prepare", params: ["cwd": "/Users/me/api"]) == nil)
    }
}
