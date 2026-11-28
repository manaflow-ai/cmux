import CmuxNextCloud
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A Cloud start in a GitHub repository with no folder on this Mac (`cwd: github:owner/name`): the App
/// gets the repository and no folder, a chat here is refused with words, and a machine with no access
/// answers the card's Connect GitHub, then Retry on the same machine.
@MainActor
struct AgentPaneCloudStartRepositoryTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class Starts { var seen: [AgentPaneCloudStart] = [] }

    private static func params(_ cwd: String) -> [String: Any] { ["task": "fix the build", "cwd": cwd, "key": UUID().uuidString] }

    @Test func aGitHubFolderIsARepositoryNotAPath() throws {
        let start = try #require(AgentPaneCloudStart(params: Self.params("github:acme/api")))
        #expect(start.repository == "acme/api")
        #expect(start.cwd == nil)
        #expect(!start.home)
        let folder = try #require(AgentPaneCloudStart(params: Self.params("/Users/me/api")))
        #expect(folder.repository == nil)
        #expect(folder.cwd == "/Users/me/api")
        // A malformed name, or a repository with `home`, is no start at all.
        #expect(AgentPaneCloudStart(params: Self.params("github:acme")) == nil)
        #expect(AgentPaneCloudStart(params: Self.params("github:acme/api/x")) == nil)
        #expect(AgentPaneCloudStart(params: Self.params("github:acme/api").merging(["home": true]) { $1 }) == nil)
    }

    /// Add project's Git URL with Cloud picked (`cwd: git:URL`): any host's https URL is a repository the machine
    /// clones, read by Rust's `cloud_machine_repo_parse`; a chat here is refused like `github:`.
    @Test func aGitURLFolderIsARepositoryOnAnyHost() throws {
        let gitlab = try #require(AgentPaneCloudStart(params: Self.params("git:https://gitlab.com/gitlab-org/gitlab-test")))
        #expect(gitlab.repository == "https://gitlab.com/gitlab-org/gitlab-test")
        #expect(gitlab.cwd == nil)
        let repo = try #require(AgentPaneCloudStart.machineRepo("https://gitlab.com/gitlab-org/gitlab-test"))
        #expect(repo.host == "gitlab.com")
        #expect(repo.owner == "gitlab-org")
        #expect(repo.name == "gitlab-test")
        #expect(!repo.isGitHub)
        let github = try #require(AgentPaneCloudStart.machineRepo("https://github.com/octocat/Hello-World.git"))
        #expect(github.isGitHub)
        #expect(github.name == "Hello-World")
        #expect(AgentPaneCloudStart.machineRepo("acme/api")?.isGitHub == true)
        #expect(AgentPaneCloudStart(params: Self.params("git:")) == nil)
        #expect(AgentPaneCloudStart(params: Self.params("git:not a url")) == nil)
        #expect(AgentPaneGitHubFolder.isRepository("git:https://gitlab.com/a/b"))
        #expect(!AgentPaneGitHubFolder.isRepository("/Users/me/api"))
    }

    @Test func aChatHereIsRefusedAGitURL() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        let reply = await model.respond(to: .useFolder("git:https://gitlab.com/gitlab-org/gitlab-test", confirm: false))
        let error = reply["error"] as? [String: Any]
        #expect(error?["code"] as? String == "github.cloud_only")
    }

    @Test func aRepositoryStartReachesTheAppWithNoFolder() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        let starts = Starts()
        model.onCloudStartChat = { start in starts.seen.append(start); return AgentPaneReply.success(["machine": "cloud-1"]) }
        model.transport.gestures.record()
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "cloud.startChat", "params": Self.params("github:acme/api")]))
        #expect(reply["ok"] as? Bool == true)
        #expect(starts.seen.map(\.repository) == ["acme/api"])
        #expect(starts.seen.first?.cwd == nil)
        #expect(starts.seen.first?.uploadRoot == nil)
    }

    @Test func aChatHereIsRefusedARepositoryWithWords() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        let reply = await model.respond(to: .useFolder("github:acme/api", confirm: false))
        let error = reply["error"] as? [String: Any]
        #expect(error?["code"] as? String == "github.cloud_only")
        #expect((error?["userMessage"] as? String)?.isEmpty == false)
    }

    /// The page's local start (`chat.new`) of a chat in a repository sends `session/new {cwd: "github:..."}`:
    /// refused before any folder fill, with the reason the host words (``AgentPaneGitHubFolder/cloudOnlyReason``).
    @Test func aNewChatHereInARepositoryIsRefusedWithItsReason() throws {
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "session/new", "params": ["cwd": "github:acme/api", "mcpServers": []]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
        guard case .failure(let refusal) = AcpmuxPathPolicy.checkNow(text, scope: AcpmuxPathPolicy.Scope(roots: ["/tmp"])) else {
            Issue.record("a github: folder started a chat here")
            return
        }
        #expect(refusal.error == .pathInvalid)
        #expect(refusal.reason == "github.cloud_only")
        #expect(refusal.method == "session/new")
    }

    @Test func noAccessIsConnectGitHubThenRetryOnTheSameMachine() {
        let needs = AgentPaneCloudRepositoryRefusal.needsGitHub("acme/api").reply
        let error = needs["error"] as? [String: Any]
        #expect(error?["code"] as? String == "seed.needs_github")
        #expect(error?["retryable"] as? Bool == true)
        #expect((error?["details"] as? [String: Any])?["repo"] as? String == "acme/api")
        #expect((error?["userMessage"] as? String)?.contains("acme/api") == true)
        let failed = AgentPaneCloudRepositoryRefusal.failed("acme/api").reply
        #expect((failed["error"] as? [String: Any])?["code"] as? String == "cloud_start_failed")
        // Retry clones on the machine the start already has: the refusal never strands it.
        #expect(!CloudMoveCLI.StartChatPlan.strands(AgentPaneCloudRepositoryRefusal.needsGitHub("acme/api")))
        #expect(!CloudMoveCLI.StartChatPlan.strands(AgentPaneCloudRepositoryRefusal.failed("acme/api")))
    }

    /// A reused machine can answer `running`: another start's run, whose answer names its own repository
    /// or none. Only this start's own run (or this same step, already finished) is waited for as its clone.
    @Test func onlyThisStartsOwnRunIsItsClone() {
        #expect(AgentPaneCloudStart.clonesHere("started"))
        #expect(AgentPaneCloudStart.clonesHere("skipped"))
        #expect(!AgentPaneCloudStart.clonesHere("running"))
        #expect(!AgentPaneCloudStart.clonesHere("failed"))
    }
}
