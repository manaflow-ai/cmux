import Foundation

/// `cmux comments` — read-only access to diff-viewer review comments.
extension CMUXCLI {
    static let commentsUsage = String(
        localized: "cli.comments.usage",
        defaultValue: """
        Usage: cmux comments <subcommand> [options]

        Review comments saved from the diff viewer, stored per git repository.

        Subcommands:
          list [--repo <path>] [--all] [--json]
            List review comments for a repository (default: the git repository
            containing the current directory). Lists pending comments only;
            --all includes comments already delivered to an agent through a
            TextBox submission.
        """
    )

    func runCommentsNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.commentsUsage)
            return
        }
        guard let sub = commandArgs.first?.lowercased() else {
            throw CLIError(message: "comments requires a subcommand. Try: list")
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "list", "ls":
            let (repoOption, remainder) = parseOption(rest, name: "--repo")
            let includeConsumed = remainder.contains("--all")
            let startPath = repoOption ?? FileManager.default.currentDirectoryPath
            var params: [String: Any] = ["repo_root": try commentsGitRepoRoot(startingAt: startPath)]
            if includeConsumed {
                params["include_consumed"] = true
            }
            let payload = try client.sendV2(method: "comments.list", params: params)
            printCommentsListPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: "Unknown comments subcommand '\(sub)'. Try: list")
        }
    }

    private func commentsGitRepoRoot(startingAt directory: String) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            timeout: 10
        )
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.timedOut, result.status == 0, !root.isEmpty else {
            throw CLIError(message: "cmux comments requires a git repository: \(directory)")
        }
        return root
    }

    private func printCommentsListPayload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let comments = payload["comments"] as? [[String: Any]] ?? []
        let repoRoot = payload["repo_root"] as? String ?? ""
        guard !comments.isEmpty else {
            print("No review comments. (repo: \(repoRoot))")
            return
        }
        print("\(comments.count) review comment\(comments.count == 1 ? "" : "s") (repo: \(repoRoot))")
        for comment in comments {
            let filePath = comment["filePath"] as? String ?? "?"
            let startLine = intFromAny(comment["startLine"]) ?? 0
            let endLine = intFromAny(comment["endLine"]) ?? startLine
            let range = endLine > startLine ? "\(startLine)-\(endLine)" : "\(startLine)"
            let state = comment["consumedAt"] == nil ? "pending" : "consumed"
            print("- \(filePath):\(range) [\(state)]")
            if let lineText = comment["lineText"] as? String, !lineText.isEmpty {
                print("    anchor: \(lineText)")
            }
            if let message = comment["message"] as? String, !message.isEmpty {
                print("    \(message)")
            }
        }
    }
}
