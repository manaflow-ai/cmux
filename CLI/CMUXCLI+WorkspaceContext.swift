import Foundation

extension CMUXCLI {
    static let workspaceContextUsage = String(localized: "cli.workspace.context.usage", defaultValue: """
    cmux workspace set [--workspace <id|ref|index>] [--window <id|ref|index>] [flags]

      --directory <path>   Assign the workspace directory (aliases: --cwd, --working-directory)
      --pr <url|number>    Assign a pull request; numbers also require --pr-url <url>
      --pr-label <label>  Badge label (default: PR)
      --pr-state <state>  open, merged, or closed (default: open)
      --pr-branch <name>  Optional branch metadata
      --clear-directory  Resume following terminal directories
      --clear-pr         Resume automatic pull request display

    Sets persistent workspace context for sidebars, file actions, and new terminals.
    Existing terminals keep their cwd. PR state is explicitly reported, not polled.
    Defaults to the caller's workspace. An explicit --window uses that window's selection.

      cmux workspace set --directory ./worktrees/task
      cmux workspace set --pr https://github.com/acme/project/pull/123
      cmux workspace set --clear-directory --clear-pr
    """)

    func runWorkspaceSetCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceArg, rem0) = parseOption(commandArgs, name: "--workspace")
        let (windowOpt, rem1) = parseOption(rem0, name: "--window")
        let (directoryOpt, rem2) = parseOption(rem1, name: "--directory")
        let (workingDirectoryOpt, rem3) = parseOption(rem2, name: "--working-directory")
        let (cwdOpt, rem4) = parseOption(rem3, name: "--cwd")
        let (prOpt, rem5) = parseOption(rem4, name: "--pr")
        let (pullRequestOpt, rem6) = parseOption(rem5, name: "--pull-request")
        let (urlOpt, rem7) = parseOption(rem6, name: "--pr-url")
        let (labelOpt, rem8) = parseOption(rem7, name: "--pr-label")
        let (stateOpt, rem9) = parseOption(rem8, name: "--pr-state")
        let (branchOpt, remaining) = parseOption(rem9, name: "--pr-branch")
        let clearDirectory = remaining.contains("--clear-directory")
        let clearPR = remaining.contains("--clear-pr")
        let directories = [directoryOpt, workingDirectoryOpt, cwdOpt].compactMap { $0 }
        let prInputs = [prOpt, pullRequestOpt].compactMap { $0 }
        let hasPR = !prInputs.isEmpty || urlOpt != nil || labelOpt != nil || stateOpt != nil || branchOpt != nil
        guard remaining.allSatisfy({ ["--clear-directory", "--clear-pr"].contains($0) }),
              directories.count <= 1, prInputs.count <= 1,
              !(clearDirectory && !directories.isEmpty), !(clearPR && hasPR),
              !directories.isEmpty || hasPR || clearDirectory || clearPR else {
            throw CLIError(message: Self.workspaceContextUsage)
        }

        var params: [String: Any] = ["action": "set_context"]
        if let directory = directories.first {
            guard !directory.isEmpty, !directory.contains("\u{0}") else {
                throw CLIError(message: Self.workspaceContextUsage)
            }
            params["workspace_directory"] = resolvePath(directory)
        }
        if clearDirectory { params["clear_directory"] = true }
        if clearPR { params["clear_pull_request"] = true }
        if hasPR {
            guard let raw = prInputs.first else { throw CLIError(message: Self.workspaceContextUsage) }
            let url: String?
            let number: Int?
            if let parsed = URL(string: raw), parsed.host != nil {
                let parts = parsed.path.split(separator: "/")
                guard urlOpt == nil, parts.count >= 2,
                      ["pull", "merge_requests"].contains(String(parts[parts.count - 2])) else {
                    throw CLIError(message: Self.workspaceContextUsage)
                }
                number = parts.last.flatMap { Int($0) }
                url = raw
            } else {
                number = Int(raw.hasPrefix("#") ? String(raw.dropFirst()) : raw)
                url = urlOpt
            }
            guard let number, number > 0, let url else { throw CLIError(message: Self.workspaceContextUsage) }
            params["pr_number"] = number
            params["pr_url"] = url
            if let labelOpt { params["pr_label"] = labelOpt }
            if let stateOpt { params["pr_state"] = stateOpt }
            if let branchOpt { params["pr_branch"] = branchOpt }
        }

        let windowRaw = windowOpt ?? windowOverride
        let windowID = try normalizeWindowHandle(windowRaw, client: client)
        if let windowID { params["window_id"] = windowID }
        let target = workspaceArg ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        params["workspace_id"] = try resolveWorkspaceId(target, client: client, windowHandle: windowID)
        let payload = try client.sendV2(method: "workspace.action", params: params)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))
    }
}
