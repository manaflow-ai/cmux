import CmuxNextAgentPane
import Foundation

/// Reads a Markdown file's ``MarkdownFileLocation``: its `~` form and, in a git repository, the
/// branch, upstream, GitHub repository and the file's state
/// (plans/cmux-next/markdown-omnibar-DESIGN.md section 3). Every git command is read-only.
nonisolated struct MarkdownFileLocationReader: Sendable {
    let runner: any MarkdownGitRunning
    let home: String

    init(runner: any MarkdownGitRunning = ProcessMarkdownGitRunner(), home: String = NSHomeDirectory()) {
        self.runner = runner
        self.home = home
    }

    func read(_ file: URL) async -> MarkdownFileLocation {
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let display = MarkdownFileLocation.tildePath(path, home: home)
        return MarkdownFileLocation(path: path, displayPath: display, git: await git(path))
    }

    private func git(_ path: String) async -> MarkdownGitLocation? {
        let folder = (path as NSString).deletingLastPathComponent
        guard let top = await runner.run(["rev-parse", "--show-toplevel"], in: folder), top.status == 0 else { return nil }
        let rootLine = top.output.trimmingCharacters(in: .newlines)
        guard !rootLine.isEmpty else { return nil }
        let root = URL(fileURLWithPath: rootLine).resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        guard let output = await runner.run(["status", "--porcelain=v2", "--branch", "--ignored=matching", "--", relative], in: root),
              output.status == 0 else { return nil }
        let status = MarkdownGitStatus.parse(output.output)
        // The raw configured URL: `remote get-url` applies `insteadOf` rewrites.
        let remote = await runner.run(["config", "--get", "remote.origin.url"], in: root)
        let repository = remote.flatMap { $0.status == 0 ? AgentPaneGitHubRepository.parse($0.output) : nil }
        let state: MarkdownGitLocation.State
        switch status.file {
        case .modified: state = .modified
        case .untracked: state = .untracked
        case .ignored: state = .ignored
        case .clean:
            if status.upstream == nil {
                state = .unpushed
            } else if status.ahead == 0 {
                state = .pushed
            } else {
                // Ahead of the upstream: pushed still when this file is the same there.
                let diff = await runner.run(["diff", "--quiet", "@{upstream}", "HEAD", "--", relative], in: root)
                state = diff?.status == 0 ? .pushed : .unpushed
            }
        }
        return MarkdownGitLocation(root: root, relativePath: relative, branch: status.branch, oid: status.oid, upstream: status.upstream,
                                   ahead: status.ahead, githubRepository: repository, state: state)
    }
}
