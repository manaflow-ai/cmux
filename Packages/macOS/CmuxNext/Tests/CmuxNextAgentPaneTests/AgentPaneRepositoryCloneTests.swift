import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneRepositoryCloneTests {
    private struct GitCall: Sendable {
        var arguments: [String]
        var environment: [String: String]
    }

    private actor Git {
        var calls: [GitCall] = []
        var origin = ""
        let fail: Bool
        let occupy: URL?

        init(fail: Bool = false, occupy: URL? = nil) {
            (self.fail, self.occupy) = (fail, occupy)
        }

        func run(_ arguments: [String], folder: String?, environment: [String: String]) -> AgentPaneGitHubCheckout.GitRun? {
            calls.append(GitCall(arguments: arguments, environment: environment))
            if arguments.first == "rev-parse", let folder {
                return .init(status: FileManager.default.fileExists(atPath: folder + "/.git") ? 0 : 128, stdout: folder + "\n")
            }
            if arguments.first == "config" { return .init(status: 0, stdout: origin + "\n") }
            guard arguments.first == "clone", let partial = arguments.last, arguments.count >= 2 else { return nil }
            origin = arguments[arguments.count - 2]
            do {
                try FileManager.default.createDirectory(atPath: partial + "/.git", withIntermediateDirectories: true)
                if let occupy { try FileManager.default.createDirectory(at: occupy, withIntermediateDirectories: true) }
            } catch { return nil }
            return .init(status: fail ? 128 : 0, stdout: "private-text-from-git")
        }
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "repo-clone-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func clone(_ git: Git, under root: URL) -> AgentPaneRepositoryClone {
        AgentPaneRepositoryClone(root: root) { arguments, folder, environment, _ in
            await git.run(arguments, folder: folder, environment: environment)
        }
    }

    private func request(_ url: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "repo.clone", "params": ["url": url, "idempotency_key": "clone-1"]])
    }

    @Test func clonesIntoTheHostOwnerAndNameAndReusesTheMatchingCheckout() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Git()
        let service = clone(git, under: root)
        let remote = "https://git.example.test/group/team/api.git"
        let destination = root.appending(path: "git.example.test/group/team/api").path
        let initial = try await service.checkout(url: remote, key: "one").get()
        let replay = try await service.checkout(url: remote, key: "one").get()
        #expect(initial.path == destination)
        #expect(initial.cloned)
        #expect(replay.path == destination)
        #expect(!replay.cloned)
        let clones = await git.calls.filter { $0.arguments.first == "clone" }
        let call = try #require(clones.first)
        #expect(clones.count == 1)
        #expect(call.arguments.prefix(4) == ["clone", "--quiet", "--", remote])
        #expect(call.environment == ["GIT_ALLOW_PROTOCOL": "https"])
        #expect(call.arguments.last?.contains("/.api.cloning-") == true)
        // The same repository without `.git` (or with another host case) is the checkout already there.
        let again = try await service.checkout(url: "https://GIT.example.test/group/team/api/", key: "two").get()
        #expect(again.path == destination)
        #expect(!again.cloned)
        #expect(await service.checkout(url: "https://git.example.test/group/team/web", key: "one") == .failure(.keyConflict))
    }

    @Test(arguments: [
        "http://git.example.test/acme/api", "git@github.com:acme/api", "acme/api",
        "https://user:private-text@git.example.test/acme/api", "https://git.example.test/acme/api?token=private-text",
        "https://github.com/acme/api/tree/main", "https://git.example.test/../api",
    ])
    func rejectsNonCloneURLsBeforeGit(url: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Git()
        let result = await clone(git, under: root).checkout(url: url, key: "one")
        let containsCredentials = url.contains("private-text")
        #expect(result == .failure(containsCredentials ? .credentials : .invalidURL))
        #expect(await git.calls.isEmpty)
    }

    @Test func anExistingCheckoutsSSHOriginReadsAsItsHTTPSForm() {
        typealias Clone = AgentPaneRepositoryClone
        #expect(Clone.httpsForm(of: "git@github.com:acme/api.git\n") == "https://github.com/acme/api.git")
        #expect(Clone.httpsForm(of: "ssh://git@github.com/acme/api") == "https://github.com/acme/api")
        #expect(Clone.httpsForm(of: "ssh://git@git.example.test:2222/group/api.git") == "https://git.example.test/group/api.git")
        #expect(Clone.httpsForm(of: "https://github.com/acme/api") == "https://github.com/acme/api")
        #expect(Clone.httpsForm(of: "/Users/me/api") == "/Users/me/api")
    }

    @Test func aGitHubURLUsesTheGitHubPickersLayout() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = clone(Git(), under: root)
        let checkout = try await service.checkout(url: "https://github.com/acme/api.git", key: "one").get()
        // `~/cmux/repos/<owner>/<name>`, where the GitHub row checks it out, never a second copy under the host.
        #expect(checkout.path == root.appending(path: "acme/api").path)
        let again = try await service.checkout(url: "https://github.com/acme/api", key: "two").get()
        #expect(again.path == checkout.path)
        #expect(!again.cloned)
    }

    @Test func aFolderThatAppearsDuringCloneWinsAndTheStagingFolderIsRemoved() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "git.example.test/acme/api")
        let service = clone(Git(occupy: destination), under: root)
        #expect(await service.checkout(url: "https://git.example.test/acme/api", key: "one") == .failure(.destinationTaken))
        let files = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(files == ["api"])
    }

    @Test func remoteAndNoGestureAreRefusedAndGitOutputStaysOffThePage() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Git(fail: true)
        let model = AgentPaneModel(host: NoHost())
        model.gitWritesHere = { true }
        model.repositoryClone = clone(git, under: root)
        let request = request("https://git.example.test/acme/api")
        #expect(request.description == "repo.clone")
        #expect(AgentPageOps.method(for: AgentPageOps.namespace + "repo.clone") == "repo.clone")
        model.remoteChat = true
        let remote = await model.respond(to: request, userGesture: true)
        #expect(remote["ok"] as? Bool == false)
        model.remoteChat = false
        let noClick = await model.respond(to: request)
        #expect((noClick["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(await git.calls.isEmpty)
        let failure = await model.respond(to: request, userGesture: true)
        #expect((failure["error"] as? [String: Any])?["code"] as? String == "repo.clone_failed")
        #expect(!String(describing: failure).contains("private-text-from-git"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "git.example.test/acme").path)
        #expect(files.isEmpty)
    }

    @Test func refusesSymlinkedParentsAndExistingNonCheckoutFolders() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "git.example.test"), withDestinationURL: outside)
        let git = Git()
        let service = clone(git, under: root)
        #expect(await service.checkout(url: "https://git.example.test/acme/api", key: "one") == .failure(.destinationTaken))
        #expect(await git.calls.isEmpty)
        let occupied = root.appending(path: "example.test/acme/api", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        #expect(await service.checkout(url: "https://example.test/acme/api", key: "two") == .failure(.destinationTaken))
        #expect(await git.calls.filter { $0.arguments.first == "clone" }.isEmpty)
    }
}
