import Foundation
import CmuxNextSettings
import CmuxNextCompat

/// The Git repository a project folder belongs to, for the pickers (`project.list` `repos`): the
/// page folds a repository's worktrees under one row named for the repository, with each
/// worktree's branch as its second line. `root` is the main checkout (the folder that holds the
/// shared `.git`), the same for every worktree of the repository.
nonisolated struct AgentPaneProjectRepo: Equatable, Sendable {
    var root: String
    /// The checkout holding the folder (its main checkout or worktree): a folder inside it is
    /// named by its path below this, not by the checkout's branch alone.
    var top: String
    var name: String
    var branch: String?
    /// `owner/repo` when `origin` is on GitHub: the owner's avatar is the badge of last resort.
    var github: String?

    /// The page's shape: absent fields are left out.
    var reply: [String: Any] {
        var value: [String: Any] = ["root": root, "top": top, "name": name]
        if let branch { value["branch"] = branch }
        if let github { value["github"] = github }
        return value
    }
}

/// Reads a folder's repository from the few small files Git keeps (`.git`, `commondir`, `HEAD`,
/// `config`), never by running `git`: the list asks for up to 40 folders each time a picker opens.
///
/// Every path goes through the same privacy check as the favicons (AgentPaneProjectIcon): a
/// `gitdir:` line can point anywhere, so a worktree whose Git folder is in Documents is no
/// repository rather than a privacy prompt (LAUNCH-NO-TCC-PROMPTS).
nonisolated struct AgentPaneProjectRepoReader: Sendable {
    static let shared = AgentPaneProjectRepoReader()
    /// Git's own files here are a line or two; a large `config` still has `origin` near the top.
    static let maximumBytes = 16 * 1024
    /// A chat's folder is usually the checkout or a folder or two inside it.
    static let maximumLevels = 6

    var read: @Sendable (String) -> Data?
    private var icon: AgentPaneProjectIcon

    init(home: String = NSHomeDirectory()) {
        icon = AgentPaneProjectIcon(home: home)
        read = { path in
            guard let handle = try? FileHandle.blockingForReading(from: URL(fileURLWithPath: path)) else { return nil }
            defer { try? handle.close() }
            return try? handle.blockingRead(upToCount: AgentPaneProjectRepoReader.maximumBytes)
        }
    }

    /// The repositories of `folders`, keyed by folder as given; folders in no repository are absent.
    /// One batch: a folder the walks share (`/Users`, the home folder, a projects folder) is checked
    /// once, not once per Git file of every folder.
    func repos(for folders: [String]) -> [String: AgentPaneProjectRepo] {
        let reader = batched()
        var found: [String: AgentPaneProjectRepo] = [:]
        for folder in folders.prefix(AgentPaneOmnibar.maximumEntries) {
            if let repo = reader.repo(for: folder) { found[folder] = repo }
        }
        return found
    }

    /// A copy for one answer (``AgentPaneProjectIcon/batched()``).
    func batched() -> AgentPaneProjectRepoReader {
        var copy = self
        copy.icon = icon.batched()
        return copy
    }

    /// A copy that checks through `icon`'s batch (``AgentPaneProjectIcon/batched(sharing:)``).
    func batched(sharing icon: AgentPaneProjectIcon) -> AgentPaneProjectRepoReader {
        var copy = self
        copy.icon = self.icon.batched(sharing: icon)
        return copy
    }

    /// The `project.list` reply's `repos`, read off the main actor.
    static func replies(for folders: [String], reader: AgentPaneProjectRepoReader = .shared) async -> [String: Any] {
        await Task.detached(priority: .utility) {
            reader.repos(for: folders)
        }.value.mapValues(\.reply)
    }

    /// The repository holding `folder`: its own `.git`, or the nearest parent's, below the home folder.
    func repo(for folder: String) -> AgentPaneProjectRepo? {
        var current = Self.normalized(folder)
        for _ in 0..<Self.maximumLevels {
            guard current.hasPrefix("/"), current != "/", allows(current) else { return nil }
            if var repo = repo(at: current) {
                repo.top = current
                return repo
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The repository whose `.git` is directly in `folder`.
    private func repo(at folder: String) -> AgentPaneProjectRepo? {
        let dotGit = folder + "/.git"
        let gitDir: String
        if let head = text(dotGit + "/HEAD") {
            // A main checkout: `.git` is the repository's own folder.
            return repo(commonDir: dotGit, head: head)
        } else if let link = text(dotGit), let line = link.split(separator: "\n").first, line.hasPrefix("gitdir:") {
            // A linked worktree: `.git` is a file naming its folder inside the main `.git/worktrees`.
            gitDir = Self.resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines), from: folder)
        } else if let head = text(folder + "/HEAD"), let config = text(folder + "/config"), Self.isBare(config) {
            // A bare repository (a lane mirror, `cmux.git`): the folder is the repository itself, so a
            // chat in it still has its GitHub origin and its owner's avatar.
            return repo(commonDir: folder, head: head)
        } else {
            return nil
        }
        guard let head = text(gitDir + "/HEAD") else { return nil }
        guard let commonDir = text(gitDir + "/commondir") else {
            // A submodule (`gitdir: ../.git/modules/sub`) or a checkout with a separate Git folder:
            // its own repository, rooted where its `.git` file is.
            return repo(commonDir: gitDir, root: folder, head: head)
        }
        return repo(commonDir: Self.resolve(commonDir.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDir), head: head)
    }

    private func repo(commonDir: String, root given: String? = nil, head: String) -> AgentPaneProjectRepo? {
        guard allows(commonDir) else { return nil }
        let root: String
        if let given {
            root = given
        } else if commonDir.hasSuffix("/.git") {
            root = String(commonDir.dropLast("/.git".count))
        } else if (commonDir as NSString).lastPathComponent.hasPrefix(".") {
            // A bare repository kept in a hidden folder of its checkout (`cmux/.bare`) is named for the checkout.
            root = (commonDir as NSString).deletingLastPathComponent
        } else {
            root = commonDir
        }
        guard root.hasPrefix("/"), root != "/" else { return nil }
        let github = text(commonDir + "/config").flatMap(Self.origin).flatMap(AgentPaneGitHubRepository.parse)
        var name = github.flatMap { $0.split(separator: "/").last.map(String.init) } ?? (root as NSString).lastPathComponent
        if github == nil, name.hasSuffix(".git"), name.count > 4 { name = String(name.dropLast(4)) }
        return AgentPaneProjectRepo(root: root, top: root, name: name, branch: Self.branch(head), github: github)
    }

    /// The file's text, only when its path and its resolved path may be read.
    private func text(_ path: String) -> String? {
        guard allows(path) else { return nil }
        if let resolved = Self.realPath(path), resolved != path, !allows(resolved) { return nil }
        return read(path).map { String(decoding: $0, as: UTF8.self) }
    }

    private func allows(_ path: String) -> Bool { icon.allows(path) }

    /// The branch `HEAD` is on; nil when it is detached (a commit id).
    static func branch(_ head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: refs/heads/") else { return nil }
        let name = String(line.dropFirst("ref: refs/heads/".count))
        return name.isEmpty ? nil : name
    }

    /// Whether a Git config says `bare = true` in its `[core]` section.
    static func isBare(_ config: String) -> Bool {
        var inCore = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("[") {
                inCore = line.replacingOccurrences(of: " ", with: "") == "[core]"
                continue
            }
            if inCore, line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "") == "bare=true" { return true }
        }
        return false
    }

    /// The `url` of `[remote "origin"]` in a Git config.
    static func origin(_ config: String) -> String? {
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "").lowercased() == "[remote\"origin\"]"
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `path` against `base` when relative, with `.` and `..` folded lexically: `standardizingPath`
    /// would drop `/private` and stat the disk.
    static func resolve(_ path: String, from base: String) -> String {
        normalized(path.hasPrefix("/") ? path : base + "/" + path)
    }

    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func realPath(_ path: String) -> String? {
        // SAFETY: realpath reads the NUL-terminated copy of `path` made for the call and returns a malloc'd
        // NUL-terminated string or nil; it is copied once into the result, then freed once.
        guard let resolved = unsafe blockingRealpath(path, nil) else { return nil }
        defer { unsafe free(resolved) }
        return unsafe String(cString: resolved)
    }
}
