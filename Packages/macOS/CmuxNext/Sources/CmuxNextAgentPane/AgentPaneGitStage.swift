import Foundation

/// The Changes view's Stage and Unstage (cx-tcwj, Codex desktop's staging): `git.stage` and
/// `git.unstage` with `{cwd, paths}`. The App runs `git add` or `git restore --staged` in `cwd` on
/// those files, as the user's own git does. It needs a real click or key in the pane, `cwd` inside
/// the pane's folders, and paths that never leave the repository.
public nonisolated struct AgentPaneGitStage: Equatable, Sendable {
    public enum Action: String, Sendable {
        case stage, unstage
    }

    public let action: Action
    /// The chat's folder, absolute.
    public let cwd: String
    /// Files relative to the top of `cwd`'s repository, as `git.diff` names them.
    public let paths: [String]

    /// The most files one request names.
    public static let maximumPaths = 1000
    /// How long git may take before the request fails.
    static let timeout: Duration = .seconds(20)

    /// Nil unless `method` is `git.stage` or `git.unstage`, `cwd` is absolute, and `paths` holds 1
    /// to ``maximumPaths`` relative paths without `..` segments or NUL.
    public init?(method: String, params: [String: Any]?) {
        let action: Action
        switch method {
        case "git.stage": action = .stage
        case "git.unstage": action = .unstage
        default: return nil
        }
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"),
              let paths = params?["paths"] as? [String], (1...Self.maximumPaths).contains(paths.count),
              paths.allSatisfy(Self.isInside) else { return nil }
        self.action = action
        self.cwd = cwd
        self.paths = paths
    }

    /// A path that names something under its folder: relative, no `..` segment, no NUL.
    static func isInside(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// git's arguments. Literal pathspecs from the repository's top after `--`: a file named like
    /// an option or a glob is that file, and a chat in a subfolder names files as `git.diff` does.
    var arguments: [String] {
        let pathspecs = paths.map { ":(top,literal)" + $0 }
        switch action {
        case .stage: return ["-C", cwd, "add", "--"] + pathspecs
        case .unstage: return ["-C", cwd, "restore", "--staged", "--"] + pathspecs
        }
    }

    /// Runs the request when `cwd` is inside one of `roots`. Nil on success, else git's message or
    /// why it did not run.
    static func run(_ request: AgentPaneGitStage, roots: [String]) async -> String? {
        let canonicalRoots = roots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        guard let folder = AcpmuxPathPolicy.canonical(request.cwd),
              canonicalRoots.contains(where: { AcpmuxPathPolicy.contains(root: $0, path: folder) }) else {
            return outsideMessage
        }
        return await AgentPaneGitProcess.run(request.arguments, timeout: timeout)
    }
}

/// One `git` run for the pane's writes: `/usr/bin/git` with a plain environment, no prompt for
/// credentials, and a deadline.
nonisolated enum AgentPaneGitProcess {
    /// Nil when git exits 0, else its first error line (or why it did not run).
    static func run(_ arguments: [String], input: Data? = nil, timeout: Duration) async -> String? {
        await Task.detached(priority: .userInitiated) {
            runSync(arguments, input: input, timeout: timeout)
        }.value
    }

    /// The process, for the deadline's queue.
    private final class Held: @unchecked Sendable {
        let process = Process()
    }

    private static func runSync(_ arguments: [String], input: Data?, timeout: Duration) -> String? {
        let held = Held(), process = held.process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = environment()
        let errors = Pipe(), stdin = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { return error.localizedDescription }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            if held.process.isRunning { held.process.terminate() }
        }
        // concurrency-allow: runSync runs only inside the detached task; git's error output is small.
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        // concurrency-allow: runSync runs only inside the detached task, bounded by the deadline above.
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let text = String(decoding: message, as: UTF8.self)
        return text.split(separator: "\n").first.map { String($0) } ?? "git exited \(process.terminationStatus)"
    }

    /// The user's own git settings (HOME) and none of the App's environment; never a terminal
    /// prompt for credentials.
    static func environment() -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { environment["HOME"] = home }
        return environment
    }
}

extension AgentPaneGitStage {
    /// `git.stage` or `git.unstage` arrived without a real click or key press in the pane.
    nonisolated static var needsGestureMessage: String {
        String(localized: "agentPane.error.gitStageGesture", defaultValue: "Staging needs a click or key press in the pane.",
               bundle: .module)
    }

    /// `git.stage` or `git.unstage` whose params break its contract.
    nonisolated static var invalidMessage: String {
        String(localized: "agentPane.error.gitStageInvalid", defaultValue: "The app refused the staging request.", bundle: .module)
    }

    /// The repository is outside the pane's folders.
    nonisolated static var outsideMessage: String {
        String(localized: "agentPane.error.gitStageOutside", defaultValue: "That folder is outside this chat's folders.",
               bundle: .module)
    }

    /// `git.stage` / `git.unstage` (nil: params that break the contract): spends `model`'s GRANT
    /// credit, then runs git in the chat's folder.
    @MainActor static func reply(to request: AgentPaneGitStage?, in model: AgentPaneModel) async -> [String: Any] {
        guard let request else { return AgentPaneReply.failure(code: "native.invalid_request", message: invalidMessage) }
        guard model.transport.gestures.consume() else {
            return AgentPaneReply.failure(code: AgentPaneTransportError.gestureRequired.rawValue,
                                          message: needsGestureMessage, details: nil, retryable: nil, origin: "native")
        }
        if let message = await run(request, roots: model.roots() + model.transport.addedRoots) {
            return AgentPaneReply.failure(code: "git.failed", message: message)
        }
        return AgentPaneReply.success()
    }
}
