import Foundation

/// The Changes view's Stage and Unstage (cx-tcwj, Codex desktop's staging): `git.stage` and
/// `git.unstage` with `{cwd, paths}`. The App runs `git add` or `git restore --staged` in `cwd` on
/// those files, as the user's own git does. Stage hunk and Unstage hunk (cx-ncc.74) are
/// `git.stageHunk` and `git.unstageHunk` with `{cwd, paths: [path, previous path of a rename], hunk}`: `hunk` is one hunk's
/// lines as `git.diff` showed them; the App finds that hunk in its own read of the file's diff and
/// applies only it to the index, so the page never writes content into it. Each needs a real click
/// or key in the pane, `cwd` inside the pane's folders, and paths that never leave the repository.
public nonisolated struct AgentPaneGitStage: Equatable, Sendable {
    public enum Action: String, Sendable {
        case stage, unstage
    }

    public let action: Action
    /// The chat's folder, absolute.
    public let cwd: String
    /// Files relative to the top of `cwd`'s repository, as `git.diff` names them.
    public let paths: [String]
    /// One hunk of `paths[0]` (whose rename source is `paths[1]`): its lines, each ` `, `-` or `+`
    /// then the text; nil for whole files.
    public let hunk: [String]?

    /// The most files one request names.
    public static let maximumPaths = 1000
    /// The longest hunk one request names, in UTF-8 bytes.
    public static let maximumHunkBytes = 1 << 20
    /// How long git may take before the request fails.
    static let timeout: Duration = .seconds(20)

    /// Nil unless `method` is `git.stage`, `git.unstage`, `git.stageHunk` or `git.unstageHunk`, `cwd`
    /// is absolute, and `paths` holds 1 to ``maximumPaths`` relative paths without NUL or `.`, `..`
    /// or empty segments; a hunk request names one path (two for a rename) and a ``isHunk(_:)`` hunk.
    public init?(method: String, params: [String: Any]?) {
        let action: Action
        let hunk: [String]?
        switch method {
        case "git.stage": (action, hunk) = (.stage, nil)
        case "git.unstage": (action, hunk) = (.unstage, nil)
        case "git.stageHunk", "git.unstageHunk":
            guard let lines = params?["hunk"] as? [String], Self.isHunk(lines) else { return nil }
            (action, hunk) = (method == "git.stageHunk" ? .stage : .unstage, lines)
        default: return nil
        }
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"),
              let paths = params?["paths"] as? [String], (1...Self.maximumPaths).contains(paths.count),
              hunk == nil || paths.count <= 2, paths.allSatisfy(Self.isInside) else { return nil }
        self.action = action
        self.cwd = cwd
        self.paths = paths
        self.hunk = hunk
    }

    /// Hunk lines: each ` `, `-` or `+` then text without a line break or NUL, at least one of them
    /// a change, at most ``maximumHunkBytes`` in all.
    static func isHunk(_ lines: [String]) -> Bool {
        lines.contains { $0.utf8.first == UInt8(ascii: "-") || $0.utf8.first == UInt8(ascii: "+") }
            && lines.reduce(0) { $0 + $1.utf8.count + 1 } <= maximumHunkBytes
            && lines.allSatisfy { line in
                AgentPaneGitHunk.isHunkRow(line) && !line.utf8.contains { $0 == 0x0A || $0 == 0x0D || $0 == 0 }
            }
    }

    /// A path that names something under the repository's top and never the top itself: relative,
    /// no NUL, no `.`, `..` or empty segment (so not `.`, `a/.` or `a//b`).
    static func isInside(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !["", ".", ".."].contains($0) }
    }

    /// git's arguments in `folder`, the chat's folder resolved. Literal pathspecs from the
    /// repository's top after `--`: a file named like an option or a glob is that file, and a chat
    /// in a subfolder names files as `git.diff` does.
    func arguments(in folder: String) -> [String] {
        let pathspecs = paths.map { ":(top,literal)" + $0 }
        switch action {
        case .stage: return ["-C", folder, "add", "--"] + pathspecs
        case .unstage: return ["-C", folder, "restore", "--staged", "--"] + pathspecs
        }
    }

    /// Runs the request where ``AgentPaneGitProcess/place(_:roots:home:)`` allows (`home` defaults
    /// to the user's). Nil on success, else git's message or why it did not run.
    @concurrent public static func run(_ request: AgentPaneGitStage, roots: [String], home: String? = nil) async -> String? {
        switch await AgentPaneGitProcess.place(request.cwd, roots: roots, home: home ?? NSHomeDirectory()) {
        case .refused(let message): return message
        case .folder(let folder):
            guard let hunk = request.hunk else { return await AgentPaneGitProcess.run(request.arguments(in: folder), timeout: timeout) }
            return await runHunk(hunk, of: request.paths, unstage: request.action == .unstage, in: folder)
        }
    }

    /// Reads the file's diff as `git.diff` does (the index against the worktree to stage, HEAD
    /// against the index to unstage), and applies its hunk whose lines are `hunk` to the index. A
    /// rename reads both of its paths, so its hunks pair as the view's do. Blank context lines read
    /// as " " whatever the user's `diff.suppressBlankEmpty`, as the view shows them.
    private static func runHunk(_ hunk: [String], of paths: [String], unstage: Bool, in folder: String) async -> String? {
        let read = ["-C", folder, "-c", "diff.suppressBlankEmpty=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative",
                    "--ignore-submodules=dirty", "-M", "--src-prefix=a/", "--dst-prefix=b/"]
            + (unstage ? ["--cached"] : []) + ["--"] + paths.map { ":(top,literal)" + $0 }
        let diff = await AgentPaneGitProcess.output(read, timeout: timeout)
        guard diff.status == 0 else { return diff.message }
        guard let patch = AgentPaneGitHunk.patch(of: hunk, in: diff.text) else { return hunkMovedMessage }
        let apply = ["-C", folder, "apply", "--cached", "--whitespace=nowarn"] + (unstage ? ["--reverse"] : []) + ["-"]
        return await AgentPaneGitProcess.run(apply, input: Data(patch.utf8), timeout: timeout)
    }
}

extension AgentPaneGitStage {
    /// `git.stage` or `git.unstage` arrived without a real click or key press in the pane.
    public nonisolated static var needsGestureMessage: String {
        String(localized: "agentPane.error.gitStageGesture", defaultValue: "Staging needs a click or key press in the pane.",
               bundle: .module)
    }

    /// `git.stage` or `git.unstage` whose params break its contract.
    public nonisolated static var invalidMessage: String {
        String(localized: "agentPane.error.gitStageInvalid", defaultValue: "The app refused the staging request.", bundle: .module)
    }

    /// The hunk is not in the file's diff any more (the file changed since the view read it).
    nonisolated static var hunkMovedMessage: String {
        String(localized: "agentPane.error.gitHunkMoved", defaultValue: "That change is no longer in the file. Refresh and try again.",
               bundle: .module)
    }

    /// The repository is outside the pane's folders.
    nonisolated static var outsideMessage: String {
        String(localized: "agentPane.error.gitStageOutside", defaultValue: "That folder is outside this chat's folders.",
               bundle: .module)
    }

    /// `git.stage` / `git.unstage` (nil: params that break the contract): spends `model`'s GRANT
    /// credit, then runs git in the chat's folder, for a chat on this Mac only.
    @MainActor static func reply(to request: AgentPaneGitStage?, in model: AgentPaneModel) async -> [String: Any] {
        guard let request else { return AgentPaneReply.failure(code: "native.invalid_request", message: invalidMessage) }
        guard model.gitWritesHere?() == true else {
            return AgentPaneReply.failure(code: "git.remote", message: AgentPaneGitProcess.remoteMessage)
        }
        guard model.transport.gestures.consume() else {
            return AgentPaneReply.failure(code: AgentPaneTransportError.gestureRequired.rawValue,
                                          message: needsGestureMessage, details: nil, retryable: nil, origin: "native")
        }
        if let message = await run(request, roots: model.fileOpenRoots()) {
            return AgentPaneReply.failure(code: "git.failed", message: message)
        }
        return AgentPaneReply.success()
    }
}
