public import CmuxNextWakeups
public import Foundation

/// Everything a Cloud machine for a chat needs, read from the chat's folder with no prompt (leo-workspace
/// design/cloud-work-mode.md, "Auto-sizing"). This runs the local git commands and lists the folder; Rust reads
/// what they printed (`moves::autosize::work_pick`).
public struct CloudWorkPick: Equatable, Sendable {
    /// The working copy's top (git), else the chat's folder itself.
    public var root: String
    /// `host/owner/name`, lower-cased, from the remote; nil outside git or with no remote it can name.
    public var repoKey: String?
    /// The GitHub repository a new machine can clone, at ``branch``'s remote branch when that is pushed.
    public var repo: CloudMachineRepo?
    /// The branch checked out; nil when detached or outside git.
    public var branch: String?
    /// ``branch`` has an upstream that holds every commit of it.
    public var pushed: Bool
    public var sizeMb: Int?
    public var rootFiles: [String]
    public var taskKind: CloudTaskKind
    /// ``root`` has a `.cmux/machine.toml`.
    public var hasMachineConfig: Bool
    /// The chat's agent is Codex, whose sign-in on a machine comes from the Codex broker.
    public var needsCodexBroker: Bool

    public init(root: String, repoKey: String? = nil, repo: CloudMachineRepo? = nil, branch: String? = nil, pushed: Bool = false,
                sizeMb: Int? = nil, rootFiles: [String] = [], taskKind: CloudTaskKind = .chat, hasMachineConfig: Bool = false,
                needsCodexBroker: Bool = false) {
        (self.root, self.repoKey, self.repo, self.branch, self.pushed) = (root, repoKey, repo, branch, pushed)
        (self.sizeMb, self.rootFiles, self.taskKind, self.hasMachineConfig, self.needsCodexBroker) = (sizeMb, rootFiles, taskKind, hasMachineConfig, needsCodexBroker)
    }

    /// The create's `autosize`.
    public var autosize: CloudAutosizeRequest {
        CloudAutosizeRequest(taskKind: taskKind, repoKey: repoKey, repoSizeMb: sizeMb, rootFiles: rootFiles)
    }

    /// How long one git command may take; a slow one leaves its fact out, never the pick.
    public static let gitTimeout: Duration = .seconds(3)

    private struct Facts: Encodable {
        var folder: String, text: String?, harness: String?, top: String?, branch: String?, upstream: String?, remote: String?, objects: String?
        var names: [String], machineConfig: Bool
    }

    /// The GitHub repo the Rust pick names (`machine_repo::Repo`): its ref is set only when it is pushed and safe to quote.
    private struct PickedRepo: Decodable {
        var owner: String, name: String, ref: String?
    }

    private struct Picked: Decodable {
        var root: String, repoKey: String?, repo: PickedRepo?, branch: String?, pushed: Bool, sizeMb: Int?, rootFiles: [String]
        var taskKind: CloudTaskKind, hasMachineConfig: Bool, needsCodexBroker: Bool
    }

    /// Reads the pick for a chat in `folder` (absolute, on this Mac), for its prompt or title `text` and agent `harness`.
    /// Every git command is local and bounded by ``gitTimeout``; one that fails leaves its fact out. The folder listing
    /// runs on `work` (it may block on the disk).
    public static func read(folder: String, text: String?, harness: String?, work: BackgroundWork,
                            git: URL = URL(fileURLWithPath: "/usr/bin/git")) async -> CloudWorkPick {
        let run = { (arguments: [String]) async -> String? in
            let request = ProcessRequest(git, ["-C", folder] + arguments, environment: gitEnvironment, timeout: gitTimeout)
            guard let outcome = try? await AsyncProcess().run(request), outcome.succeeded else { return nil }
            let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let top = await run(["rev-parse", "--show-toplevel"])
        let root = top ?? folder
        let branch = top == nil ? nil : await run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let upstream = branch == nil ? nil : await run(["for-each-ref", "--format=%(upstream:remoteref)%00%(upstream:track)%00%(upstream:remotename)",
                                                       "refs/heads/" + (branch ?? "")])
        // The branch's own remote (a fork's `origin` beside the `upstream` it tracks), else git's default.
        struct Upstream: Encodable { var upstream: String }
        struct Named: Decodable { var name: String? }
        let remoteName = upstream.flatMap { CloudMoveCore().call("work_pick_remote", Upstream(upstream: $0), as: Named.self)?.name }
        let remote = top == nil ? nil : await run(["ls-remote", "--get-url"] + (remoteName.map { [$0] } ?? []))
        let objects = top == nil ? nil : await run(["count-objects", "-v"])
        let listing = try? await work.run(.userBlocking, mayBlock: .files) { listRoot(root) }
        let facts = Facts(folder: folder, text: text, harness: harness, top: top, branch: branch, upstream: upstream, remote: remote,
                          objects: objects, names: listing?.names ?? [], machineConfig: listing?.machineConfig ?? false)
        guard let picked = CloudMoveCore().call("work_pick", facts, as: Picked.self) else { return CloudWorkPick(root: root) }
        let repo = picked.repo.map { CloudMachineRepo(owner: $0.owner, name: $0.name, ref: $0.ref) }
        return CloudWorkPick(root: picked.root, repoKey: picked.repoKey, repo: repo,
                             branch: picked.branch, pushed: picked.pushed, sizeMb: picked.sizeMb, rootFiles: picked.rootFiles,
                             taskKind: picked.taskKind, hasMachineConfig: picked.hasMachineConfig, needsCodexBroker: picked.needsCodexBroker)
    }

    /// git with no pager, no prompt and no optional locks (a pick never writes the index).
    static let gitEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        return environment
    }()

    /// The names at `root` (Rust keeps those within the server's limits), and whether `.cmux/machine.toml` is there.
    static func listRoot(_ root: String) -> (names: [String], machineConfig: Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return (names, FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".cmux/machine.toml")))
    }
}
