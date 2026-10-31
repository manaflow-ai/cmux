import CmuxNextWakeups
import Foundation

/// What one `git` run printed on its output and how it exited.
nonisolated struct MarkdownGitOutput: Equatable, Sendable {
    var status: Int32
    var output: String
}

/// Runs read-only `git` commands for the Markdown omnibar; tests may pass a fake.
nonisolated protocol MarkdownGitRunning: Sendable {
    /// `git -C folder <arguments>`; nil when git did not run or ran past its deadline.
    func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput?
}

/// `/usr/bin/git` with no prompts and no optional locks (a status never takes the index lock an
/// editor or agent may hold), stopped at a deadline so a hung filesystem never holds the bar.
nonisolated struct ProcessMarkdownGitRunner: MarkdownGitRunning {
    var timeout: Duration = .seconds(5)

    func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? {
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
