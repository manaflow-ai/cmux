import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The New Tab omnibar's folder completion (`folder.complete {path}`): an absolute folder's
/// subfolders, names only, for "Codex in ~/fun/cm…". Never a listing inside a macOS
/// privacy-protected folder (LAUNCH-NO-TCC-PROMPTS), and a protected child of the home folder is
/// never offered; hidden folders, files and packages are left out.
struct AgentPaneFolderCompletionTests {
    private static let home = "/Users/me"

    /// Every folder the fake disk was asked to list.
    private nonisolated final class Listed: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    private static func completion(_ listed: Listed, _ disk: [String: [(String, Bool)]]) -> AgentPaneFolderCompletion {
        AgentPaneFolderCompletion(home: home) { path in
            listed.add(path)
            return disk[path].map { $0.map { (name: $0.0, folder: $0.1) } }
        }
    }

    @Test func aFolderListsItsSubfoldersByNameWithoutFilesHiddenFoldersOrPackages() {
        let listed = Listed()
        let completion = Self.completion(listed, [
            "/Users/me/fun": [("cmux", true), ("README.md", false), (".git", true), ("games", true), ("Cmux10", true),
                              ("cmux2", true)],
        ])
        #expect(completion.folders(in: "/Users/me/fun") == ["cmux", "cmux2", "Cmux10", "games"])
        #expect(listed.all == ["/Users/me/fun"])
    }

    @Test func theHomeFolderListsButNeverOffersItsProtectedFolders() {
        let listed = Listed()
        let completion = Self.completion(listed, [
            "/Users/me": [("Documents", true), ("Desktop", true), ("Downloads", true), ("fun", true), ("code", true)],
        ])
        #expect(completion.folders(in: "/Users/me") == ["code", "fun"])
    }

    /// "/Users/" completes to the home folder: refused as a chat root, yet the way to the projects.
    @Test func theUsersFolderOffersTheHomeFolder() {
        let listed = Listed()
        let completion = Self.completion(listed, ["/Users": [("me", true), ("Shared", true)]])
        #expect(completion.folders(in: "/Users/") == ["me", "Shared"])
    }

    @Test func aProtectedFolderIsNeverListed() {
        let listed = Listed()
        let completion = Self.completion(listed, ["/Users/me/Documents": [("secret", true)]])
        #expect(completion.folders(in: "/Users/me/Documents") == nil)
        #expect(completion.folders(in: "/Users/me/Desktop/") == nil)
        #expect(listed.all.isEmpty)
    }

    @Test func aRelativeOrClimbingPathIsRefusedBeforeTheDisk() {
        let listed = Listed()
        let completion = Self.completion(listed, ["/Users/me": [("fun", true)]])
        #expect(completion.folders(in: "fun") == nil)
        #expect(completion.folders(in: "/Users/me/fun/../Documents") == nil)
        #expect(completion.folders(in: "/Users/me/\u{0}") == nil)
        #expect(listed.all.isEmpty)
        #expect(Self.request("/Users/me/../Documents").isUnsupported)
        #expect(Self.request("relative").isUnsupported)
        #expect(!Self.request("/Users/me/fun").isUnsupported)
    }

    private static func request(_ path: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "folder.complete", "params": ["path": path]])
    }

    /// A chat on another machine never lists this Mac's disk: its folders are there.
    @MainActor
    @Test func aRemoteChatGetsNoFolders() async throws {
        let remote = AgentPaneModel(host: NoHost())
        remote.remoteChat = true
        let reply = await remote.respond(to: .completeFolder("/"))
        #expect((reply["value"] as? [String: Any])?["folders"] as? [String] == [])
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}

private extension AgentPaneRequest {
    var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }
}
