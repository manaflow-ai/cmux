import Foundation

extension CMUXCLI {
    static let issuesUsage = """
        Usage: cmux issues <list|refresh|open|spawn> [options]

        Aggregate configured GitHub and Linear issues through Issue Inbox.

          cmux issues list [--json]
              Print cached issues. Does not force a refresh.

          cmux issues refresh [--json]
              Refresh all configured sources and report per-source results.

          cmux issues open
              Open or focus the Issue Inbox surface in the current workspace.

          cmux issues spawn <issue-id> [--cwd <path>] [--json]
              Create or reuse a cmux workspace for the issue. Uses --cwd or
              the source's configured projectRoot.
        """

    func runIssuesCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let sub = commandArgs.first?.lowercased() ?? "list"
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "help", "--help", "-h":
            print(Self.issuesUsage)

        case "list", "ls":
            try rejectUnexpectedIssueArgs(rest, command: "issues list")
            let response = try client.sendV2(method: "issues.list")
            if jsonOutput {
                print(jsonString(formatIDs(response, mode: idFormat)))
                return
            }
            printIssuesTable(response)

        case "refresh":
            try rejectUnexpectedIssueArgs(rest, command: "issues refresh")
            let response = try client.sendV2(method: "issues.refresh", responseTimeout: 125)
            if jsonOutput {
                print(jsonString(formatIDs(response, mode: idFormat)))
                return
            }
            printIssueRefreshResult(response)

        case "open":
            try rejectUnexpectedIssueArgs(rest, command: "issues open")
            let response = try client.sendV2(method: "issues.open")
            printV2Payload(
                response,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallbackText: v2OKSummary(response, idFormat: idFormat, kinds: ["surface", "workspace"])
            )

        case "spawn":
            let (cwd, remaining) = parseOption(rest, name: "--cwd")
            let flags = remaining.filter { $0.hasPrefix("-") }
            if let flag = flags.first {
                throw CLIError(message: "issues spawn: unknown option '\(flag)'")
            }
            let positionals = remaining
            guard let issueID = positionals.first, !issueID.isEmpty else {
                throw CLIError(message: "issues spawn requires an issue id")
            }
            if positionals.count > 1 {
                throw CLIError(message: "issues spawn: unexpected argument '\(positionals[1])'")
            }
            var params: [String: Any] = ["issue_id": issueID]
            if let cwd, !cwd.isEmpty {
                params["cwd"] = cwd
            }
            let response = try client.sendV2(method: "issues.spawn_workspace", params: params)
            printV2Payload(
                response,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallbackText: issueSpawnSummary(response)
            )

        default:
            throw CLIError(message: """
                Unknown issues subcommand: \(sub)

                \(Self.issuesUsage)
                """)
        }
    }

    private func rejectUnexpectedIssueArgs(_ args: [String], command: String) throws {
        if let first = args.first {
            throw CLIError(message: "\(command): unexpected argument '\(first)'")
        }
    }

    private func printIssuesTable(_ response: [String: Any]) {
        let items = response["items"] as? [[String: Any]] ?? []
        if items.isEmpty {
            print("No issues.")
            printIssueSourceErrors(response)
            return
        }
        print(
            "\(issuePad("PROVIDER", 8))  \(issuePad("NUMBER", 12))  \(issuePad("STATUS", 6))  \(issuePad("SOURCE", 24))  TITLE"
        )
        for item in items {
            let provider = (item["provider"] as? String) ?? "?"
            let number = (item["number"] as? String) ?? "?"
            let status = (item["status"] as? String) ?? "?"
            let source = (item["repo_or_project"] as? String) ?? "?"
            let title = (item["title"] as? String) ?? ""
            print(
                "\(issuePad(provider, 8))  \(issuePad(number, 12))  \(issuePad(status, 6))  \(issuePad(issueTruncate(source, max: 24), 24))  \(issueTruncate(title, max: 80))"
            )
        }
        printIssueSourceErrors(response)
    }

    private func printIssueRefreshResult(_ response: [String: Any]) {
        let perSource = response["per_source"] as? [String: Any] ?? [:]
        if perSource.isEmpty {
            print("No issue sources configured.")
            return
        }
        for sourceID in perSource.keys.sorted() {
            let value = perSource[sourceID] as? [String: Any] ?? [:]
            if let count = value["count"] {
                print("\(sourceID): \(count) issues")
            } else {
                print("\(sourceID): ERROR \(value["error"] ?? "Unknown error")")
            }
        }
    }

    private func printIssueSourceErrors(_ response: [String: Any]) {
        let sourceErrors = response["source_errors"] as? [String: Any] ?? [:]
        for sourceID in sourceErrors.keys.sorted() {
            print("ERROR \(sourceID): \(sourceErrors[sourceID] ?? "Unknown error")")
        }
    }

    private func issueSpawnSummary(_ response: [String: Any]) -> String {
        let reused = (response["reused"] as? Bool) == true
        let workspace = (response["workspace_ref"] as? String)
            ?? (response["workspace_id"] as? String)
            ?? "workspace"
        return reused ? "Reused \(workspace)" : "Created \(workspace)"
    }

    private func issuePad(_ value: String, _ width: Int) -> String {
        let clipped = issueTruncate(value, max: width)
        let padding = max(0, width - clipped.count)
        return clipped + String(repeating: " ", count: padding)
    }

    private func issueTruncate(_ value: String, max: Int) -> String {
        guard value.count > max, max > 3 else { return value }
        return String(value.prefix(max - 3)) + "..."
    }
}
