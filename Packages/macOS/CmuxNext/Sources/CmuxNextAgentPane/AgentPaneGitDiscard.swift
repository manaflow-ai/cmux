public import Foundation

/// The diff tab's Revert (D3, the Codex Review pane's): it throws away changes git keeps nowhere,
/// so the diff tab asks first for files (DiffPageProvider+Revert.swift) and offers Undo for a hunk.
/// `git.discard {cwd, paths, scope}` reverts whole files; `git.discardHunk {cwd, paths, scope, hunk}`
/// one hunk of one file (its lines as the diff showed them, as for Stage hunk). `scope` is what the
/// page shows, and so what the person sees go:
/// - `unstaged`: the work tree goes back to the index. Staged changes stay.
/// - `uncommitted`: the index and the work tree go back to HEAD. Staged changes go too.
/// A file git does not track (new in the work tree, intent-to-add, or new in the index for
/// `uncommitted`) goes to the Trash with its content, never `rm`, so the person can still take it
/// back. Only a file git itself lists as untracked or new moves, and only when its folder resolves
/// inside the repository. A submodule is refused: its checkout is never reset.
/// A hunk is reverse-applied to the work tree only, from the App's own read of the file's diff; a
/// hunk that is not in that read, one that creates or deletes the file (a whole-file revert, which
/// asks first), or (for `uncommitted`) a file with staged changes, reverts nothing.
/// Every git run turns off submodule recursion and the fsmonitor hook (``git(_:)``).
public nonisolated struct AgentPaneGitDiscard: Equatable, Sendable {
    /// The folder the request runs in, absolute.
    public let cwd: String
    /// Files relative to the top of `cwd`'s repository, as the diff names them.
    public let paths: [String]
    /// `unstaged` or `uncommitted`.
    public let scope: AgentPaneGitScope
    /// One hunk of `paths[0]` (whose rename source is `paths[1]`); nil for whole files.
    public let hunk: [String]?

    /// What a revert did.
    public enum Outcome: Equatable, Sendable {
        /// Done. `undo` puts a reverted hunk back; nil for files.
        case reverted(undo: Undo?)
        /// Nothing or not all of it reverted: git's message, or why it did not run.
        case failed(String)
    }

    /// A reverted hunk's way back: its patch, which `git apply` applies again, while the file's
    /// content is still what the revert left (`hash`, git's blob id of the work-tree file).
    public struct Undo: Equatable, Sendable {
        public let patch: String
        /// The file, relative to the repository's top.
        public let path: String
        public let hash: String

        public init(patch: String, path: String, hash: String) {
            self.patch = patch
            self.path = path
            self.hash = hash
        }
    }

    /// How long one git run may take.
    static let timeout: Duration = .seconds(20)

    /// Nil unless `method` is `git.discard` or `git.discardHunk`, `scope` is `unstaged` or
    /// `uncommitted`, `cwd` is absolute, and `paths` holds 1 to ``AgentPaneGitStage/maximumPaths``
    /// distinct relative paths that stay inside the repository; a hunk request names one path (two
    /// for a rename) and a hunk with at least one change.
    public init?(method: String, params: [String: Any]?) {
        let hunk: [String]?
        switch method {
        case "git.discard": hunk = nil
        case "git.discardHunk":
            guard let lines = params?["hunk"] as? [String], AgentPaneGitStage.isHunk(lines) else { return nil }
            hunk = lines
        default: return nil
        }
        guard let raw = params?["scope"] as? String, let scope = AgentPaneGitScope(rawValue: raw),
              scope == .unstaged || scope == .uncommitted,
              let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"),
              let paths = params?["paths"] as? [String], (1...AgentPaneGitStage.maximumPaths).contains(paths.count),
              Set(paths).count == paths.count, hunk == nil || paths.count <= 2,
              paths.allSatisfy(AgentPaneGitStage.isInside) else { return nil }
        self.cwd = cwd
        self.paths = paths
        self.scope = scope
        self.hunk = hunk
    }

    /// Runs the request where ``AgentPaneGitProcess/place(_:roots:home:)`` allows (`home` defaults
    /// to the user's), from the top of the repository.
    /// Moves one file to the Trash (tests pass their own folder, so they never touch the real Trash).
    public typealias Trashing = @Sendable (URL) throws -> Void
    public static let systemTrash: Trashing = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    @concurrent public static func run(_ request: AgentPaneGitDiscard, roots: [String], home: String? = nil,
                                       trash: @escaping Trashing = AgentPaneGitDiscard.systemTrash) async -> Outcome {
        let repository: String
        switch await top(of: request.cwd, roots: roots, home: home) {
        case .refused(let message): return .failed(message)
        case .folder(let folder): repository = folder
        }
        if let hunk = request.hunk { return await revertHunk(hunk, of: request.paths, scope: request.scope, in: repository) }
        if let message = await revertFiles(request.paths, scope: request.scope, in: repository, trash: trash) { return .failed(message) }
        return .reverted(undo: nil)
    }

    /// Applies a reverted hunk again: Undo. Nil on success, else why not: the file changed since the
    /// revert (so the patch could land in the wrong place), or git's message.
    @concurrent public static func reapply(_ undo: Undo, cwd: String, roots: [String], home: String? = nil) async -> String? {
        switch await top(of: cwd, roots: roots, home: home) {
        case .refused(let message): return message
        case .folder(let repository):
            guard AgentPaneGitStage.isInside(undo.path) else { return undoChangedMessage }
            let current = await Self.hash(undo.path, in: repository)
            guard current == undo.hash else { return undoChangedMessage }
            return await AgentPaneGitProcess.run(Self.git(repository) + ["apply", "--whitespace=nowarn", "-"],
                                                 input: Data(undo.patch.utf8), timeout: timeout)
        }
    }

    /// git in `repository` with the settings a revert must not follow: no submodule recursion (a
    /// revert never resets a submodule's checkout) and no fsmonitor hook.
    static func git(_ repository: String) -> [String] {
        ["-C", repository, "-c", "submodule.recurse=false", "-c", "core.fsmonitor=false"]
    }

    /// git's blob id of the work-tree file `path`, or nil when git cannot read it.
    static func hash(_ path: String, in repository: String) async -> String? {
        let outcome = await AgentPaneGitProcess.output(Self.git(repository) + ["hash-object", "--", path], timeout: timeout)
        let hash = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return outcome.status == 0 && !hash.isEmpty ? hash : nil
    }

    /// The top of `cwd`'s repository, links resolved, when the pane may write there.
    private static func top(of cwd: String, roots: [String], home: String?) async -> AgentPaneGitProcess.Place {
        switch await AgentPaneGitProcess.place(cwd, roots: roots, home: home ?? NSHomeDirectory()) {
        case .refused(let message): return .refused(message)
        case .folder(let folder):
            let top = await AgentPaneGitProcess.output(["-C", folder, "rev-parse", "--show-toplevel"], timeout: timeout)
            guard top.status == 0, let repository = AcpmuxPathPolicy.canonical(top.text.trimmingCharacters(in: .newlines)) else {
                return .refused(top.message)
            }
            return .folder(repository)
        }
    }

    /// Literal pathspecs from the repository's top: a file named like an option or a glob is that file.
    static func pathspecs(_ paths: [String]) -> [String] {
        paths.map { ":(top,literal)" + $0 }
    }

    /// Reads the file's diff as Stage hunk does (the index against the work tree) and applies its hunk
    /// whose lines are `hunk` to the work tree in reverse. `uncommitted` shows HEAD against the work
    /// tree, which is that read only while the file has nothing staged.
    static func revertHunk(_ hunk: [String], of paths: [String], scope: AgentPaneGitScope, in repository: String) async -> Outcome {
        let git = Self.git(repository)
        if scope == .uncommitted {
            let staged = await AgentPaneGitProcess.output(
                git + ["diff", "--cached", "--quiet", "--no-ext-diff", "--ignore-submodules=dirty", "--"] + pathspecs(paths), timeout: timeout)
            guard staged.status == 0 else { return .failed(staged.status == 1 ? stagedHunkMessage : staged.message) }
        }
        let read = git + ["-c", "diff.suppressBlankEmpty=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative",
                          "--ignore-submodules=dirty", "-M", "--src-prefix=a/", "--dst-prefix=b/", "--"] + pathspecs(paths)
        let diff = await AgentPaneGitProcess.output(read, timeout: timeout)
        guard diff.status == 0 else { return .failed(diff.message) }
        guard !wholeFile(diff.text) else { return .failed(wholeFileMessage) }
        guard let patch = AgentPaneGitHunk.patch(of: hunk, in: diff.text) else { return .failed(AgentPaneGitStage.hunkMovedMessage) }
        let apply = git + ["apply", "--reverse", "--whitespace=nowarn", "-"]
        if let message = await AgentPaneGitProcess.run(apply, input: Data(patch.utf8), timeout: timeout) { return .failed(message) }
        guard let blob = await Self.hash(paths[0], in: repository) else { return .reverted(undo: nil) }
        return .reverted(undo: Undo(patch: patch, path: paths[0], hash: blob))
    }

    /// A diff whose header creates, deletes, renames or copies the file, or names a submodule: undoing
    /// one of its hunks is a whole-file revert, which goes through the sheet.
    static func wholeFile(_ diff: String) -> Bool {
        let header = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix { !$0.hasPrefix("@@") }
        return header.contains { row in
            ["new file mode ", "deleted file mode ", "rename from ", "copy from "].contains { row.hasPrefix($0) }
                || (row.hasPrefix("index ") && row.hasSuffix(" 160000"))
        }
    }
}

extension AgentPaneGitDiscard {
    /// `git.discard` or `git.discardHunk` whose params break its contract.
    public nonisolated static var invalidMessage: String {
        String(localized: "agentPane.error.gitDiscardInvalid", defaultValue: "The app refused the revert request.", bundle: .module)
    }

    /// Revert hunk in Uncommitted on a file with staged changes.
    nonisolated static var stagedHunkMessage: String {
        String(localized: "agentPane.error.gitDiscardStagedHunk",
               defaultValue: "This file has staged changes. Revert the change in Unstaged, or revert the whole file.", bundle: .module)
    }

    /// An untracked file whose folder resolves outside the repository.
    nonisolated static var outsideMessage: String {
        String(localized: "agentPane.error.gitDiscardOutside", defaultValue: "That file is outside the repository.", bundle: .module)
    }

    /// A revert that names a submodule.
    nonisolated static var submoduleMessage: String {
        String(localized: "agentPane.error.gitDiscardSubmodule",
               defaultValue: "Submodules aren't reverted here. Revert them in their own folder.", bundle: .module)
    }

    /// A hunk revert that would create or delete the file.
    nonisolated static var wholeFileMessage: String {
        String(localized: "agentPane.error.gitDiscardWholeFile",
               defaultValue: "This change adds or removes the whole file. Revert the file instead.", bundle: .module)
    }

    /// Undo after the file changed since the revert.
    nonisolated static var undoChangedMessage: String {
        String(localized: "agentPane.error.gitDiscardUndoChanged",
               defaultValue: "The file changed after the revert, so Undo can't put the change back.", bundle: .module)
    }

    /// A revert that stopped part way: the files it did not revert.
    nonisolated static var notRevertedMessage: String {
        String(localized: "agentPane.error.gitDiscardNotReverted", defaultValue: "Not reverted: %@", bundle: .module)
    }
}
