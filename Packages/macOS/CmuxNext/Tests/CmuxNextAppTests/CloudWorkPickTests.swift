@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextWakeups
import Foundation
import Testing

/// Automatic environment choice for a chat sent to Cloud (leo-workspace design/cloud-work-mode.md,
/// "Auto-sizing"): the chat's folder alone gives the repo, its ref, its size and root files, the
/// task kind, `.cmux/machine.toml` and whether Codex needs the broker. No prompt.
@Suite(.serialized)
struct CloudWorkPickTests {
    /// A working copy with `files` at its top, an `origin` (a bare repo here, then named by
    /// `remote`), and one commit pushed when `push`.
    private static func repo(_ files: [String], remote: String? = "https://github.com/Manaflow-AI/cmux.git", push: Bool = true,
                             branch: String = "feature/pick", upstreamBranch: String? = nil,
                             remoteName: String = "origin") throws -> (folder: String, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-work-pick-\(UUID().uuidString)").path
        let folder = base + "/work", upstream = base + "/up.git"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try git(base, "init", "-q", "--bare", upstream)
        try git(folder, "init", "-q", "-b", branch)
        for file in files {
            let path = folder + "/" + file
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("x\n".utf8).write(to: URL(fileURLWithPath: path))
        }
        try git(folder, "add", "-A")
        try git(folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "first")
        try git(folder, "remote", "add", remoteName, upstream)
        if push { try git(folder, "push", "-q", "--no-verify", "-u", remoteName, branch + ":" + (upstreamBranch ?? branch)) }
        // The pushed copy is named like a hosted repo; a pick never talks to it.
        if let remote { try git(folder, "remote", "set-url", remoteName, remote) }
        return (folder, { try? FileManager.default.removeItem(atPath: base) })
    }

    @discardableResult
    private static func git(_ directory: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pick(_ folder: String, text: String? = nil, harness: String? = "claude") async -> CloudWorkPick {
        await CloudWorkPick.read(folder: folder, text: text, harness: harness, work: BackgroundWork())
    }

    @Test func aSwiftPackagesPickNamesItsRepoBranchAndRootFiles() async throws {
        let (folder, cleanup) = try Self.repo(["Package.swift", "Sources/App/main.swift", ".cmux/machine.toml"])
        defer { cleanup() }
        let pick = await Self.pick(folder + "/Sources", harness: "codex")
        #expect(pick.root.hasSuffix("/work"))
        #expect(pick.repoKey == "github.com/manaflow-ai/cmux")
        #expect(pick.repo == CloudMachineRepo(owner: "Manaflow-AI", name: "cmux", ref: "feature/pick"))
        #expect(pick.branch == "feature/pick")
        #expect(pick.pushed)
        #expect(pick.rootFiles == [".cmux", "Package.swift", "Sources"])
        #expect(pick.sizeMb.map { $0 >= 1 } == true)
        #expect(pick.hasMachineConfig)
        #expect(pick.needsCodexBroker)
        #expect(pick.taskKind == .chat)
        let body = pick.autosize.body
        #expect(body["taskKind"] as? String == "chat")
        let repo = try #require(body["repo"] as? [String: any Sendable])
        #expect(repo["key"] as? String == "github.com/manaflow-ai/cmux")
        #expect(repo["rootFiles"] as? [String] == [".cmux", "Package.swift", "Sources"])
        #expect(repo["sizeMb"] as? Int == pick.sizeMb)
    }

    @Test func aRustAndANodeRepoSendTheirToolchainFiles() async throws {
        let (rust, cleanRust) = try Self.repo(["Cargo.toml", "src/main.rs"], remote: "git@github.com:o/tool.git")
        defer { cleanRust() }
        let rustPick = await Self.pick(rust, text: "run the tests and fix what fails")
        #expect(rustPick.rootFiles == ["Cargo.toml", "src"])
        #expect(rustPick.repoKey == "github.com/o/tool")
        #expect(rustPick.taskKind == .test)
        #expect(!rustPick.needsCodexBroker)
        #expect(!rustPick.hasMachineConfig)

        let (node, cleanNode) = try Self.repo(["package.json", "index.ts"], remote: "ssh://git@gitlab.example.com:2222/group/sub/web.git")
        defer { cleanNode() }
        let nodePick = await Self.pick(node, text: "Build the release bundle")
        #expect(nodePick.rootFiles == ["index.ts", "package.json"])
        #expect(nodePick.repoKey == "gitlab.example.com/group/sub/web", "any host keys its measured runs")
        #expect(nodePick.repo == nil, "only a GitHub repo is cloned by a new machine")
        #expect(nodePick.taskKind == .build)
    }

    @Test func anUnpushedBranchIsPickedWithoutItsRef() async throws {
        let (folder, cleanup) = try Self.repo(["Package.swift"], push: false)
        defer { cleanup() }
        let pick = await Self.pick(folder)
        #expect(pick.branch == "feature/pick")
        #expect(!pick.pushed)
        #expect(pick.repo == CloudMachineRepo(owner: "Manaflow-AI", name: "cmux", ref: nil), "the machine clones the default branch")
    }

    @Test func theCloneRefIsTheUpstreamsBranchAndALocalRemoteNamesNoRepo() async throws {
        let (folder, cleanup) = try Self.repo(["Package.swift"], upstreamBranch: "topic/elsewhere")
        defer { cleanup() }
        let pick = await Self.pick(folder)
        #expect(pick.branch == "feature/pick")
        #expect(pick.repo?.ref == "topic/elsewhere", "the machine clones the branch the remote has")

        let (local, cleanLocal) = try Self.repo(["Package.swift"], remote: "octo/paint")
        defer { cleanLocal() }
        let localPick = await Self.pick(local)
        #expect(localPick.repoKey == nil)
        #expect(localPick.repo == nil, "a relative path remote is not a GitHub spec")
    }

    @Test func theCloneRefIsTheRemotesBranchUnderARemoteNameWithASlash() async throws {
        let (folder, cleanup) = try Self.repo(["Package.swift"], branch: "local", upstreamBranch: "feature", remoteName: "team/origin")
        defer { cleanup() }
        let pick = await Self.pick(folder)
        #expect(pick.pushed)
        #expect(pick.repo?.ref == "feature", "not origin/feature, the tail of refs/remotes/team/origin/feature")
    }

    @Test func theRepoIsTheTrackedRemotesNotTheDefaultOne() async throws {
        let (folder, cleanup) = try Self.repo(["Package.swift"], remote: "https://github.com/octo/cmux.git", remoteName: "upstream")
        defer { cleanup() }
        // A fork as origin, while the branch tracks upstream.
        try Self.git(folder, "remote", "add", "origin", "https://github.com/me/cmux-fork.git")
        let pick = await Self.pick(folder)
        #expect(pick.repo == CloudMachineRepo(owner: "octo", name: "cmux", ref: "feature/pick"))
        #expect(pick.repoKey == "github.com/octo/cmux")
        #expect(CloudWorkPick.remoteName("refs/heads/x\0\0upstream") == "upstream")
        #expect(CloudWorkPick.remoteName("refs/heads/x\0") == nil)
        #expect(CloudWorkPick.remoteName("refs/heads/x\0\0-c") == nil)
    }

    @Test func aFolderOutsideGitIsPickedAsItselfWithNoRepo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-work-pick-plain-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: folder + "/package.json"))
        let pick = await Self.pick(folder)
        #expect(pick.root == folder)
        #expect(pick.repoKey == nil)
        #expect(pick.repo == nil)
        #expect(pick.branch == nil)
        #expect(!pick.pushed)
        #expect(pick.sizeMb == nil)
        #expect(pick.rootFiles == ["package.json"])
        #expect(pick.autosize.body["repo"] as? [String: any Sendable] != nil, "root files alone still name the toolchain")
        let empty = CloudAutosizeRequest()
        #expect(empty.body["repo"] == nil)
        #expect(empty.body["taskKind"] as? String == "chat")
    }

    @Test func theTaskKindRuleIsWholeWordsAndTestingWins() {
        #expect(CloudTaskKind.inferred(from: nil) == .chat)
        #expect(CloudTaskKind.inferred(from: "Explain the latest changes") == .chat)
        #expect(CloudTaskKind.inferred(from: "Compile the app") == .build)
        #expect(CloudTaskKind.inferred(from: "build it, then run the e2e suite") == .test)
        #expect(CloudTaskKind.inferred(from: "Fix failing tests in Sources/") == .test)
        #expect(CloudTaskKind.inferred(from: "contest rebuilt") == .chat)
    }

    @Test func aRemoteKeyNeverKeepsALoginAndALocalRemoteHasNone() {
        #expect(CloudWorkPick.repoKey("https://x-token:ghp_secret@github.com/o/r.git") == "github.com/o/r")
        #expect(CloudWorkPick.repoKey("ghp_secret@github.com:o/r") == "github.com/o/r")
        #expect(CloudWorkPick.repoKey("/srv/git/r.git") == nil)
        #expect(CloudWorkPick.repoKey("file:///srv/git/r.git") == nil)
        #expect(CloudWorkPick.repoKey("https://github.com/only") == nil)
        #expect(CloudWorkPick.repoKey("https://github.com/o/r with space") == nil)
    }

    @Test func pushedReadsTheUpstreamTrack() {
        #expect(CloudWorkPick.isPushed("main\0"))
        #expect(CloudWorkPick.isPushed("origin/main\0[behind 2]"))
        #expect(!CloudWorkPick.isPushed("origin/main\0[ahead 1]"))
        #expect(!CloudWorkPick.isPushed("origin/main\0[ahead 1, behind 2]"))
        #expect(!CloudWorkPick.isPushed("origin/main\0[gone]"))
        #expect(!CloudWorkPick.isPushed("\0"))
        #expect(CloudWorkPick.objectsMb("count: 3\nsize: 12\nin-pack: 9\nsize-pack: 2048\n") == 3)
        #expect(CloudWorkPick.objectsMb("garbage") == nil)
    }

    /// New Cloud Machine from a chat sizes the machine for the chat only when the setup keeps
    /// the chat's own repository; the request stays a bare create (``CloudMachineRequest/isDefault``).
    @MainActor
    @Test func theSetupIsSizedOnlyForTheChatsOwnRepository() throws {
        let pick = CloudWorkPick(root: "/r", repoKey: "github.com/octo/paint", repo: CloudMachineRepo(owner: "octo", name: "paint", ref: "main"),
                                 rootFiles: ["Package.swift"])
        let same = try CloudWorkspaceSetupWizard.Plan.make(source: .repository, repositoryText: "Octo/Paint")
        #expect(CloudChatPick.request(same, sizedFor: pick).autosize == pick.autosize)
        let other = try CloudWorkspaceSetupWizard.Plan.make(source: .repository, repositoryText: "octo/brush")
        #expect(CloudChatPick.request(other, sizedFor: pick).autosize == nil)
        let empty = try CloudWorkspaceSetupWizard.Plan.make(source: .empty, repositoryText: "")
        #expect(CloudChatPick.request(empty, sizedFor: pick).autosize == nil)
        #expect(CloudChatPick.request(sizedFor: nil).autosize == nil)
        #expect(CloudChatPick.request(sizedFor: pick).autosize == pick.autosize)
        #expect(CloudChatPick.request(sizedFor: pick).isDefault)
    }

    @Test func theAnswersSizePickIsTheHandoffsSize() throws {
        let machine = try JSONDecoder().decode(CloudMachine.self, from: Data(#"""
            {"id":"vm-1","provider":"freestyle","sizePick":{"vcpus":8,"memoryGb":16,"pick":"lg","reason":"8 vCPU · 16 GB, picked from 3 earlier runs"}}
            """#.utf8))
        let pick = try #require(machine.sizePick)
        #expect(pick == CloudSizePick(vcpus: 8, memoryGb: 16, pick: "lg", reason: "8 vCPU · 16 GB, picked from 3 earlier runs"))
        #expect(pick.handoffSize["vcpus"] as? Int == 8)
        #expect(pick.handoffSize["memoryGb"] as? Double == 16)
        let bad = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-2","sizePick":{"vcpus":"x"}}"#.utf8))
        #expect(bad.sizePick == nil, "a malformed pick drops the line, never the machine")
    }
}
