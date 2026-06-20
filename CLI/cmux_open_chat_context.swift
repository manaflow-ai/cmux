import Foundation

extension CMUXCLI {
    struct OpenChatContext {
        var workspaceName: String
        var repoName: String
        var repoRoot: String?
        var branchName: String?
        var branchLabel: String
    }

    func openChatContext(cwd: String, workspaceName: String?) -> OpenChatContext {
        let resolvedCWD = standardizedDiffSourcePath(cwd)
        let repoRoot = try? gitRepoRoot(startingAt: resolvedCWD)
        let repoLabelPath = repoRoot ?? resolvedCWD
        let repoName = openChatDisplayName(forPath: repoLabelPath)
        let workspaceLabel = normalizedDiffSourceValue(workspaceName) ?? repoName
        let branchName = repoRoot.flatMap(openChatCurrentBranch(in:))
        let branchLabel = branchName ?? OpenChatLabels.localized().values["noBranch"] ?? "No branch"
        return OpenChatContext(
            workspaceName: workspaceLabel,
            repoName: repoName,
            repoRoot: repoRoot,
            branchName: branchName,
            branchLabel: branchLabel
        )
    }

    private func openChatDisplayName(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let lastPathComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastPathComponent.isEmpty {
            return lastPathComponent
        }
        return path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "cmux" : path
    }

    private func openChatCurrentBranch(in repoRoot: String) -> String? {
        if let branch = try? gitSingleLine(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot),
           branch != "HEAD",
           !branch.isEmpty {
            return branch
        }
        return try? gitSingleLine(["rev-parse", "--short", "HEAD"], in: repoRoot)
    }
}
