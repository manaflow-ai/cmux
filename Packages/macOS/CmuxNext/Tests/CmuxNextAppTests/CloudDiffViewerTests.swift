import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// The diff viewer in a Cloud workspace (#25581), on the remote diff tab of #26113: a tab whose
/// repository is on a Cloud machine reads every diff from that machine's session host and never
/// this Mac's sidecar, says by name when the machine does not answer, offers none of this Mac's
/// folders, and opens a file in the machine's file tab by its path there. Before, the tab ran the
/// local sidecar and git on the VM's path, which shows nothing or this Mac's unrelated folder of
/// the same name.
@MainActor
@Suite(.serialized)
struct CloudDiffViewerTests {
    static let repository = "/home/cmux/uploader"
    static let machine = "dev-vm"

    /// A Cloud machine's session host: `git.diff` answers `reply` (or `failure`), recording each read.
    final class MachineGit: DiffGitRunning {
        var reply: JSONValue = [:]
        var failure: AgentPaneGitFailure?
        var diffs: [(String, AgentPaneGitScope)] = []
        var staged: [AgentPaneGitStage] = []

        var isRemote: Bool { true }

        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue {
            if let failure { throw failure }
            return ["root": .string(repository)]
        }
        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue {
            diffs.append((repository, scope))
            if let failure { throw failure }
            return reply
        }
        func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? {
            staged.append(request)
            return nil
        }
    }

    /// A sidecar that records each request; a Cloud tab must never send it one.
    nonisolated final class RecordingSidecar: DiffSidecarRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [Data] = []
        var requests: [Data] { lock.withLock { _requests } }

        func run(_ request: Data) async throws -> Data {
            lock.withLock { _requests.append(request) }
            throw CancellationError()
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

    @Test func aCloudTabReadsTheMachinesDiffNeverThisMacsSidecar() async throws {
        let (grant, root) = try Self.grant()
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let git = MachineGit(), sidecar = RecordingSidecar()
        git.reply = ["files": [["path": "src/a.ts", "status": "modified", "patch": "@@ -1 +1 @@\n-old\n+new\n"]]]
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: sidecar, languages: nil,
                                        git: git, machine: Self.machine)
        let source: JSONValue = ["kind": "unstaged", "repoRoot": .string(Self.repository)]
        let opened = try await Self.call(provider, "cmux.diff.sessionOpen", ["source": source])
        #expect(opened["value"]?["source"] == source)
        #expect(git.diffs.map(\.0) == [Self.repository])
        #expect(git.diffs.map(\.1) == [.unstaged])
        #expect(try String(contentsOf: grant.remotePatchURL, encoding: .utf8).contains("diff --git a/src/a.ts b/src/a.ts"))
        #expect(sidecar.requests.isEmpty)
        await provider.close()
    }

    @Test func aCloudTabThatCannotReachItsMachineSaysSo() async throws {
        let (grant, root) = try Self.grant()
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let git = MachineGit()
        git.failure = .notConnected
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil,
                                        git: git, machine: Self.machine)
        do {
            _ = try await Self.call(provider, "cmux.diff.sessionOpen", ["source": ["kind": "unstaged", "repoRoot": .string(Self.repository)]])
            Issue.record("an offline machine opened a session")
        } catch let error as PageError {
            #expect(error.code == "cmux.diff.machine_offline")
            #expect(error.message.contains(Self.machine))
            #expect(error.retryable)
        }
        // The freshness check says it too, instead of a bare session host code.
        do {
            _ = try await Self.call(provider, "cmux.diff.git.fingerprint", ["scope": "unstaged"])
            Issue.record("an offline machine answered the freshness check")
        } catch let error as PageError {
            #expect(error.code == "cmux.diff.machine_offline")
        }
        await provider.close()
    }

    @Test func aCloudTabOffersNoneOfThisMacsFoldersAndChangesNothing() async throws {
        let (grant, root) = try Self.grant()
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let git = MachineGit(), host = DiffOpenFileTests.RecordingHost()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil,
                                        host: host, git: git, machine: Self.machine)
        // This Mac's recent folders and folder picker would name paths the machine does not have.
        await #expect(throws: PageError.self) { _ = try await Self.call(provider, "cmux.diff.recents") }
        await #expect(throws: PageError.self) { _ = try await Self.call(provider, "cmux.diff.chooseFolder") }
        await #expect(throws: PageError.self) {
            _ = try await Self.call(provider, "cmux.diff.git.stage", ["paths": ["src/a.ts"]], gesture: 1)
        }
        #expect(git.staged.isEmpty)
        await provider.close()
    }

    @Test func aCloudTabOpensTheFileByItsPathOnTheMachine() async throws {
        let (grant, root) = try Self.grant()
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let host = DiffOpenFileTests.RecordingHost()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil,
                                        host: host, git: MachineGit(), machine: Self.machine)
        let config = try await Self.call(provider, "cmux.diff.config")
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.openFile") == true)
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

    @Test func aRemoteChatsTabStillOpensNoFile() async throws {
        let (grant, root) = try Self.grant()
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let host = DiffOpenFileTests.RecordingHost()
        // No machine: a remote chat's tab (#26113), whose files no tab of this Mac reads.
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil,
                                        host: host, git: MachineGit())
        let config = try await Self.call(provider, "cmux.diff.config")
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.openFile") != true)
        await #expect(throws: PageError.self) {
            _ = try await Self.call(provider, "cmux.diff.openFile", ["path": "src/a.ts"], gesture: 1)
        }
        #expect(host.opened.isEmpty)
        await provider.close()
    }
}
