import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// The diff viewer in a Cloud workspace (#25581): a tab whose repository is on another machine
/// reads every diff from that machine's session host and renders it as a patch with this Mac's
/// sidecar, keeps the page's own source (so Refresh-on-change reads the same machine), and never
/// asks the sidecar, the editor app, Finder or this Mac's git for that repository's path. Before,
/// the tab ran the local sidecar and git on the VM's path, which shows nothing or this Mac's
/// unrelated folder of the same name.
@MainActor
@Suite(.serialized)
struct CloudDiffViewerTests {
    static let repository = "/home/cmux/uploader"
    static let machine = "dev-vm"

    /// A machine's session host: `git.diff` answers `reply` (or `failure`), recording each read.
    final class MachineGit: DiffGitRunning {
        var reply: JSONValue = [:]
        var failure: AgentPaneGitFailure?
        var diffs: [(String, AgentPaneGitScope, Bool)] = []
        var staged: [AgentPaneGitStage] = []

        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue {
            if let failure { throw failure }
            return ["root": .string(repository)]
        }
        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue {
            diffs.append((repository, scope, includePatch))
            if let failure { throw failure }
            return reply
        }
        func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? {
            staged.append(request)
            return nil
        }
    }

    /// A sidecar that records each request and opens any source as a session of it.
    nonisolated final class RecordingSidecar: DiffSidecarRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [JSONValue] = []
        var requests: [JSONValue] { lock.withLock { _requests } }

        func run(_ request: Data) async throws -> Data {
            let body = try JSONValue.parse(request)
            lock.withLock { _requests.append(body) }
            let id: JSONValue = body["id"] ?? .null
            let source: JSONValue = body["params"]?["source"] ?? .null
            let reply: JSONValue = ["id": id, "version": 1, "result": [
                "type": "sessionOpened",
                "value": ["sessionId": "11111111-2222-3333-4444-555555555555", "source": source,
                          "patch": ["id": "cmux-page://cmux.diff/__patch/t/machine.patch", "mediaType": "text/x-diff", "revision": 1],
                          "generatedPaths": []],
            ]]
            return Data(reply.compactText.utf8)
        }
    }

    private static func grant() throws -> (DiffSessionGrant, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-machine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try DiffSessionGrant.create(root: root, repository: repository), root)
    }

    private static func call(_ provider: DiffPageProvider, _ op: String, _ params: JSONValue = [:],
                             gesture: TimeInterval? = nil) async throws -> JSONValue {
        let context = gesture.map { PageCallContext(page: "cmux.diff", userGesture: true, gestureEvent: $0) }
            ?? PageCallContext(page: "cmux.diff")
        return try await provider.call(op, params: params, context: context)
    }

    @Test func aCloudTabOpensEachGitSourceAsTheMachinesDiff() async throws {
        let (grant, root) = try Self.grant()
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let git = MachineGit(), sidecar = RecordingSidecar()
        git.reply = ["files": [["path": "src/a.ts", "status": "modified", "patch": "@@ -1 +1 @@\n-old\n+new\n"]]]
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: sidecar, languages: nil,
                                        git: git, machine: Self.machine)
        let repoRoot = JSONValue.string(Self.repository)
        let sources: [(JSONValue, AgentPaneGitScope)] = [
            (["kind": "unstaged", "repoRoot": repoRoot], .unstaged),
            (["kind": "staged", "repoRoot": repoRoot], .staged),
            (["kind": "branch", "repoRoot": repoRoot, "baseRef": "HEAD"], .uncommitted),
            (["kind": "branch", "repoRoot": repoRoot, "baseRef": "origin/main"], .branch),
        ]
        for (source, scope) in sources {
            let opened = try await Self.call(provider, "cmux.diff.sessionOpen", ["source": source, "ignoreWhitespace": true])
            // The page keeps the source it asked for: its scope menu and freshness check follow it.
            #expect(opened["value"]?["source"] == source)
            #expect(git.diffs.last?.0 == Self.repository)
            #expect(git.diffs.last?.1 == scope)
            #expect(git.diffs.last?.2 == true)
        }
        // This Mac's sidecar only ever got the machine patch, never the VM's repository path.
        let opens = sidecar.requests.filter { $0["method"]?.stringValue == "sessionOpen" }
        #expect(opens.count == sources.count)
        for open in opens {
            #expect(open["params"]?["source"] == DiffMachinePatch.sidecarSource)
            #expect(open["params"]?["ignoreWhitespace"] == nil)
        }
        let written = try String(contentsOf: grant.machinePatchURL, encoding: .utf8)
        #expect(written.hasPrefix("diff --git a/src/a.ts b/src/a.ts\n"))
        // The grant's manifest lists it, so the page host serves it to this tab only.
        let listed = DiffPatchResolver(root: grant.root, token: grant.token).listedFiles().map(\.lastPathComponent)
        #expect(listed.contains(grant.machinePatchURL.lastPathComponent))
        await provider.close()
    }

    @Test func aCloudTabThatCannotReachItsMachineSaysSo() async throws {
        let (grant, root) = try Self.grant()
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let git = MachineGit(), sidecar = RecordingSidecar()
        git.failure = .notConnected
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: sidecar, languages: nil,
                                        git: git, machine: Self.machine)
        do {
            _ = try await Self.call(provider, "cmux.diff.sessionOpen", ["source": ["kind": "unstaged", "repoRoot": .string(Self.repository)]])
            Issue.record("an offline machine opened a session")
        } catch let error as PageError {
            #expect(error.code == "cmux.diff.machine_offline")
            #expect(error.message.contains(Self.machine))
        }
        // Nothing reached the sidecar, so it showed no stale or local diff.
        #expect(!sidecar.requests.contains { $0["method"]?.stringValue == "sessionOpen" })
        // The freshness check says it too, instead of a bare session host code.
        await #expect(throws: PageError.self) {
            _ = try await Self.call(provider, "cmux.diff.git.fingerprint", ["scope": "unstaged"])
        }
        await provider.close()
    }

    @Test func aCloudTabNeverReadsOrChangesThisMacsCopyOfThePath() async throws {
        let (grant, root) = try Self.grant()
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let git = MachineGit(), sidecar = RecordingSidecar()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: sidecar, languages: nil,
                                        git: git, machine: Self.machine)
        // Whole files, other bases and branch changes are the sidecar's reads of the repository.
        for method in ["fileContents", "branchList", "branchChange"] {
            do {
                _ = try await Self.call(provider, "cmux.diff.\(method)", ["sessionId": "x", "path": "src/a.ts"])
                Issue.record("\(method) reached the sidecar")
            } catch let error as PageError {
                #expect(error.code == "cmux.diff.machine_unsupported", "\(method)")
            }
        }
        #expect(sidecar.requests.isEmpty)
        // Stage and revert run git on this Mac: not offered, and refused when asked.
        let config = try await Self.call(provider, "cmux.diff.config")
        let ops = Set(config["ops"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(ops.isSuperset(of: DiffPageProvider.machineGitOps))
        #expect(!ops.contains("cmux.diff.git.stage"))
        #expect(!ops.contains("cmux.diff.git.commit"))
        #expect(!ops.contains("cmux.diff.git.discard"))
        await #expect(throws: PageError.self) {
            _ = try await Self.call(provider, "cmux.diff.git.stage", ["paths": ["src/a.ts"]], gesture: 1)
        }
        await #expect(throws: PageError.self) {
            _ = try await Self.call(provider, "cmux.diff.git.discard", ["paths": ["src/a.ts"]], gesture: 2)
        }
        #expect(git.staged.isEmpty)
        await provider.close()
    }

    @Test func aCloudTabsConfigOffersNoWholeFilesOrWhitespace() {
        let repository = DiffRepository(root: Self.repository, branch: "main", base: "origin/main")
        let local = DiffPageConfig.make(repository: repository, token: "t")["payload"]?["sessionCapabilities"]?.arrayValue
        let machine = DiffPageConfig.make(repository: repository, token: "t", onMachine: true)["payload"]?["sessionCapabilities"]?.arrayValue
        #expect(local?.isEmpty == false)
        #expect(machine == [])
    }

    @Test func aCloudTabOpensTheFileByItsPathOnTheMachine() async throws {
        let (grant, root) = try Self.grant()
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let host = DiffOpenFileTests.RecordingHost()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil,
                                        host: host, machine: Self.machine)
        // The path does not exist on this Mac; the file tab reads it on the machine.
        _ = try await Self.call(provider, "cmux.diff.openFile", ["path": "src/a.ts", "line": 3], gesture: 1)
        #expect(host.opened.map(\.0.path) == [Self.repository + "/src/a.ts"])
        #expect(host.opened.map(\.1) == [3])
        // The editor app and Finder would open this Mac's path.
        await #expect(throws: PageError.self) {
            _ = try await Self.call(provider, "cmux.diff.openFile", ["path": "src/a.ts", "where": "finder"], gesture: 2)
        }
        #expect(host.opened.count == 1)
        await provider.close()
    }
}
