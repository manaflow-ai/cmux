public import CmuxNextWakeups
public import Foundation

/// Everything a Cloud machine for a chat needs, read from the chat's folder with no prompt
/// (leo-workspace design/cloud-work-mode.md, "Auto-sizing": the person never picks a machine,
/// a size or an environment). Move to Cloud and New Cloud Machine from a chat send its
/// ``autosize`` with the create; the server answers the shape (``CloudSizePick``).
public struct CloudWorkPick: Equatable, Sendable {
    /// The working copy's top (git), else the chat's folder itself.
    public var root: String
    /// `host/owner/name`, lower-cased, from the remote: the key the server's measured runs of
    /// this repo are filed under. Nil outside git, or with no remote it can name.
    public var repoKey: String?
    /// The GitHub repository a new machine can clone (`cloud new-machine --repo`), at ``branch``
    /// when that is pushed, else at the remote's default branch. Nil for any other remote.
    public var repo: CloudMachineRepo?
    /// The branch checked out; nil when detached or outside git.
    public var branch: String?
    /// ``branch`` has an upstream that holds every commit of it; the machine clones the upstream's
    /// own branch name (``repo``'s ref), which may differ from ``branch``.
    public var pushed: Bool
    /// The repository's git objects in MiB; nil outside git.
    public var sizeMb: Int?
    /// The names at ``root``, sorted, within the server's limits.
    public var rootFiles: [String]
    public var taskKind: CloudTaskKind
    /// ``root`` has a `.cmux/machine.toml` (``CloudMachineConfig``).
    public var hasMachineConfig: Bool
    /// The chat's agent is Codex, whose sign-in on a machine comes from the Codex broker.
    public var needsCodexBroker: Bool

    public init(root: String, repoKey: String? = nil, repo: CloudMachineRepo? = nil, branch: String? = nil, pushed: Bool = false,
                sizeMb: Int? = nil, rootFiles: [String] = [], taskKind: CloudTaskKind = .chat, hasMachineConfig: Bool = false,
                needsCodexBroker: Bool = false) {
        self.root = root
        self.repoKey = repoKey
        self.repo = repo
        self.branch = branch
        self.pushed = pushed
        self.sizeMb = sizeMb
        self.rootFiles = rootFiles
        self.taskKind = taskKind
        self.hasMachineConfig = hasMachineConfig
        self.needsCodexBroker = needsCodexBroker
    }

    /// The create's `autosize`.
    public var autosize: CloudAutosizeRequest {
        CloudAutosizeRequest(taskKind: taskKind, repoKey: repoKey, repoSizeMb: sizeMb, rootFiles: rootFiles)
    }

    /// How long one git command may take; a slow one leaves its fact out, never the pick.
    public static let gitTimeout: Duration = .seconds(3)

    /// Reads the pick for a chat in `folder`.
    ///
    /// Every git command is local (no network) and bounded by ``gitTimeout``; one that fails
    /// leaves its fact out. A folder outside git is picked as itself, with no repo.
    /// - Parameters:
    ///   - folder: The chat's folder, absolute, on this Mac.
    ///   - text: The chat's prompt or title, for ``CloudTaskKind/inferred(from:)``.
    ///   - harness: The chat's agent (`codex`, `claude`, …).
    ///   - work: Where the folder listing runs (it may block on the disk).
    ///   - git: The git executable.
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
        let remoteName = upstream.flatMap(Self.remoteName)
        let remote = top == nil ? nil : await run(["ls-remote", "--get-url"] + (remoteName.map { [$0] } ?? []))
        let objects = top == nil ? nil : await run(["count-objects", "-v"])
        let listing = try? await work.run(.userBlocking, mayBlock: .files) { listRoot(root) }
        let pushed = upstream.map(isPushed) ?? false
        // The branch as the remote names it (`refs/heads/topic` there), never the local tracking ref's
        // tail, which a remote named `team/origin` or a custom fetch mapping would get wrong.
        let remoteBranch = upstream?.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first
            .flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
        // A branch name the repo step can't carry unquoted (git allows a `'`) clones the default branch.
        let ref = remoteBranch.flatMap { pushed && CloudMachineRepo.isRef($0) ? $0 : nil }
        // A local path remote (`../paint`, even `octo/paint`) has no key and names no GitHub repo.
        let key = remote.flatMap(repoKey)
        let github = key == nil ? nil : remote.flatMap { try? CloudMachineRepo.parse($0) }
        return CloudWorkPick(
            root: root, repoKey: key, repo: github.map { CloudMachineRepo(owner: $0.owner, name: $0.name, ref: ref) },
            branch: branch, pushed: pushed, sizeMb: objects.flatMap(objectsMb), rootFiles: listing?.files ?? [],
            taskKind: .inferred(from: text), hasMachineConfig: listing?.machineConfig ?? false, needsCodexBroker: harness == "codex")
    }

    /// git with no pager, no prompt and no optional locks (a pick never writes the index).
    static let gitEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        return environment
    }()

    /// The names at `root` within the server's limits, and whether `.cmux/machine.toml` is there.
    static func listRoot(_ root: String) -> (files: [String], machineConfig: Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        let files = names.filter { $0 != ".git" && $0.count <= CloudAutosizeRequest.maxNameLength }.sorted().prefix(CloudAutosizeRequest.maxRootFiles)
        let config = (root as NSString).appendingPathComponent(".cmux/machine.toml")
        return (Array(files), FileManager.default.fileExists(atPath: config))
    }

    /// `for-each-ref`'s `upstream:lstrip=3` (the remote's branch name) `NUL upstream:track`: pushed when there is an upstream and
    /// it is neither gone nor behind this branch (`[ahead N]`, `[ahead N, behind M]`).
    /// The upstream's remote name, the line's third field; nil for none or one git can't take as a name.
    static func remoteName(_ line: String) -> String? {
        let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count > 2 else { return nil }
        let name = String(parts[2])
        return name.isEmpty || name.hasPrefix("-") || name.contains(where: \.isNewline) ? nil : name
    }

    static func isPushed(_ line: String) -> Bool {
        let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
        guard let upstream = parts.first, !upstream.isEmpty else { return false }
        let track = parts.count > 1 ? parts[1] : ""
        return !track.contains("ahead") && !track.contains("gone")
    }

    /// `count-objects -v`'s loose `size` plus `size-pack` (KiB), in whole MiB, at least 1.
    static func objectsMb(_ text: String) -> Int? {
        var kib = 0, seen = false
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0] == "size" || pair[0] == "size-pack", let value = Int(pair[1]) else { continue }
            kib += value
            seen = true
        }
        return seen ? max(1, (kib + 1023) / 1024) : nil
    }

    /// `host/owner/name[/…]`, lower-cased, from a remote URL (`https://`, `ssh://`, `git://` or
    /// git's scp form `user@host:path`). Only the host and the path are kept, never a login or a
    /// password, and the key fits the server's form (autosize.ts `REPO_KEY`). A local path or a
    /// `file://` remote has no key.
    static func repoKey(_ remote: String) -> String? {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String, path: String
        if text.contains("://") {
            guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(), ["https", "http", "ssh", "git"].contains(scheme),
                  let named = url.host, !named.isEmpty else { return nil }
            host = named
            path = url.path
        } else if let colon = text.firstIndex(of: ":"), !text.hasPrefix("/") {
            let authority = text[..<colon]
            host = String(authority.split(separator: "@").last ?? authority)
            path = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        var segments = path.split(separator: "/").map(String.init)
        if let last = segments.last, last.lowercased().hasSuffix(".git") { segments[segments.count - 1] = String(last.dropLast(4)) }
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !host.isEmpty else { return nil }
        let key = ([host] + segments).joined(separator: "/").lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._~-/")
        guard key.count <= CloudAutosizeRequest.maxKeyLength, key.unicodeScalars.allSatisfy(allowed.contains),
              key.first.map({ $0.isLetter || $0.isNumber }) == true else { return nil }
        return key
    }
}
