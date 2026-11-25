import CmuxNextWakeups
import Foundation

/// What one `git` run printed on its output and how it exited.
public nonisolated struct MarkdownGitOutput: Equatable, Sendable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs read-only `git` commands for the Markdown omnibar and runbooks; tests may pass a fake.
public nonisolated protocol MarkdownGitRunning: Sendable {
    /// `git -C folder <arguments>`; nil when git did not run or ran past its deadline.
    func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput?
}

/// `/usr/bin/git` with no prompts and no optional locks (a status never takes the index lock an
/// editor or agent may hold), stopped at a deadline so a hung filesystem never holds the bar.
public nonisolated struct ProcessMarkdownGitRunner: MarkdownGitRunning {
    public var timeout: Duration = .seconds(5)

    public init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    public func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? {
        guard folder.hasPrefix("/"), !folder.contains("\0") else { return nil }
        let environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]) { _, ours in ours }
        // Awaited without a thread (AsyncProcess); the timeout ends a hung run.
        let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/git"), ["-C", folder] + arguments,
                                     environment: environment, timeout: timeout)
        guard let outcome = try? await AsyncProcess().run(request), outcome.exited else { return nil }
        return MarkdownGitOutput(status: outcome.status, output: outcome.text)
    }
}
