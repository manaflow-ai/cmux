import Foundation

/// Explicit PR handoff from a script into the existing sidebar presentation.
extension CMUXCLI {
    func runPullRequestCommand(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?,
        jsonOutput: Bool
    ) throws {
        let (workspaceArg, rest) = parseOption(commandArgs, name: "--workspace")
        let (windowArg, positional) = parseOption(rest, name: "--window")
        guard positional.count == 1,
              !positional[0].hasPrefix("-"),
              workspaceArg.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("-") }) ?? true,
              windowArg.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("-") }) ?? true else {
            throw CLIError(message: Self.pullRequestUsage)
        }
        let windowID = try normalizeWindowHandle(windowArg ?? windowOverride, client: client)
        let workspaceID = try pullRequestWorkspaceID(workspaceArg, windowID: windowID, client: client)
        let selector = positional[0]
        var tokens = ["clear_workspace_pr", "--tab=\(workspaceID)"]
        var result: [String: Any] = ["workspace_id": workspaceID, "cleared": selector == "clear"]
        if selector != "clear" {
            let metadata = try pullRequestMetadata(selector)
            tokens = [
                "report_workspace_pr", String(metadata.number), metadata.url,
                "--state=\(metadata.state)", "--tab=\(workspaceID)",
                "--branch=\(metadata.branch)"
            ]
            result["number"] = metadata.number
            result["url"] = metadata.url
            result["state"] = metadata.state
        }
        // One line-framed socket request; do not allow caller/provider text to
        // insert another command. The coordinator's tokenizer decodes escapes.
        let command = tokens[0] + " " + tokens.dropFirst().map { value in
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r") + "\""
        }.joined(separator: " ")
        let response = try sendV1Command(command, client: client)
        guard response == "OK" else { throw CLIError(message: response) }
        print(jsonOutput ? jsonString(result) : response)
    }

    /// Resolves an explicit target, live descriptor TTY, then ambient workspace.
    /// An external script may match exactly one workspace in its worktree.
    /// Mutable foreground selection is never an implicit caller identity.
    private func pullRequestWorkspaceID(
        _ explicit: String?,
        windowID: String?,
        client: SocketClient
    ) throws -> String {
        if let explicit {
            let id = try resolveWorkspaceId(explicit, client: client, windowHandle: windowID)
            if let windowID {
                let response = try client.sendV2(method: "system.identify", params: ["caller": ["workspace_id": id]])
                let caller = response["caller"] as? [String: Any]
                guard caller?["window_id"] as? String == windowID else {
                    throw CLIError(message: CMUXDiffViewerLocalization.string(
                        "cli.pr.error.workspaceMissing",
                        defaultValue: "Workspace not found; run cmux list-workspaces and retry with --workspace."
                    ))
                }
            }
            return id
        }
        var ttyWorkspace: String?
        if let tty = resolveCallerDescriptorTTYName() ?? resolveCallerTTYName(includeAmbientTTY: false) {
            let response = try client.sendV2(method: "system.identify", params: ["caller_tty": tty])
            if let caller = response["caller"] as? [String: Any],
               let id = caller["workspace_id"] as? String, isUUID(id),
               windowID == nil || caller["window_id"] as? String == windowID {
                ttyWorkspace = id
            }
        }
        if let ttyWorkspace { return ttyWorkspace }
        if windowID == nil, let raw = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try resolveWorkspaceId(raw, client: client)
        }
        let root = try pullRequestRepositoryRoot()
        let windows = try client.sendV2(method: "window.list")["windows"] as? [[String: Any]] ?? []
        var candidates = Set<String>()
        for window in windows {
            guard let id = window["id"] as? String, windowID == nil || windowID == id else { continue }
            let workspaces = try client.sendV2(method: "workspace.list", params: ["window_id": id])["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                guard let workspaceID = workspace["id"] as? String,
                      let directory = workspace["current_directory"] as? String,
                      directory.hasPrefix("/") || directory.hasPrefix("~"),
                      (workspace["remote"] as? [String: Any])?["enabled"] as? Bool != true else { continue }
                let path = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                guard path == root || path.hasPrefix(root + "/") else { continue }
                let probe = CLIProcessRunner.runProcess(
                    executablePath: "/usr/bin/env", arguments: ["git", "-C", path, "rev-parse", "--show-toplevel"],
                    stdinText: "", timeout: 2
                )
                guard probe.status == 0, !probe.timedOut else { continue }
                let candidateRoot = URL(fileURLWithPath: probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                    .standardizedFileURL.resolvingSymlinksInPath().path
                if candidateRoot == root { candidates.insert(workspaceID) }
            }
        }
        guard candidates.count == 1, let workspaceID = candidates.first else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.pr.error.ambiguousWorkspace",
                defaultValue: "cmux pr: could not identify the caller workspace; run it inside a cmux terminal or pass --workspace <id|ref|index>"
            ))
        }
        return workspaceID
    }

    private func pullRequestRepositoryRoot() throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "rev-parse", "--show-toplevel"],
            stdinText: "", timeout: 10
        )
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.timedOut, result.status == 0, !root.isEmpty else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.pr.error.notRepository",
                defaultValue: "cmux pr requires a git repository in the current directory"
            ))
        }
        return URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func pullRequestMetadata(_ selector: String) throws -> (number: Int, url: String, state: String, branch: String) {
        let numberToken = selector.hasPrefix("#") ? String(selector.dropFirst()) : selector
        let inputURL = pullRequestURL(selector)
        guard inputURL != nil || (Int(numberToken).map { $0 > 0 } == true && numberToken.allSatisfy(\.isNumber)) else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.pr.error.invalidSelector",
                defaultValue: "cmux pr expects a GitHub pull-request URL or a positive pull-request number"
            ))
        }
        let root = try pullRequestRepositoryRoot()
        // gh owns fork/upstream/default-remote selection, just as it does for
        // the preceding gh pr create. Pin the resolved repository for the PR
        // lookup so an unrelated URL cannot select a different repository.
        let repoJSON = try pullRequestGH(["repo", "view", "--json", "nameWithOwner,url,parent"], directory: root)
        guard let repository = repoJSON["nameWithOwner"] as? String,
              let repositoryURL = repoJSON["url"] as? String,
              URL(string: repositoryURL)?.host?.lowercased() == "github.com" else {
            throw pullRequestMalformedMetadataError()
        }
        let parentRepository = (repoJSON["parent"] as? [String: Any])?["nameWithOwner"] as? String
        let requestedRepository = inputURL?.repository ?? repository
        let allowedRepositories = Set([repository, parentRepository].compactMap { $0?.lowercased() })
        if !allowedRepositories.contains(requestedRepository.lowercased()) {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.pr.error.repositoryMismatch",
                defaultValue: "cmux pr: the pull request does not belong to the detected repository"
            ))
        }
        guard let requestedNumber = inputURL?.number ?? Int(numberToken) else {
            throw pullRequestMalformedMetadataError()
        }
        let object = try pullRequestGH([
            "pr", "view", String(requestedNumber), "--repo", requestedRepository,
            "--json", "number,url,state,headRefName"
        ], directory: root)
        guard let number = object["number"] as? Int, number == requestedNumber,
              let url = object["url"] as? String, let canonical = pullRequestURL(url),
              canonical.number == number, canonical.repository.caseInsensitiveCompare(requestedRepository) == .orderedSame,
              let state = object["state"] as? String, ["OPEN", "MERGED", "CLOSED"].contains(state),
              let branch = object["headRefName"] as? String else { throw pullRequestMalformedMetadataError() }
        return (number, canonical.url, state.lowercased(), branch)
    }

    private func pullRequestURL(_ raw: String) -> (repository: String, number: Int, url: String)? {
        guard let url = URLComponents(string: raw), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com", url.user == nil, url.password == nil, url.port == nil else { return nil }
        let path = url.path.split(separator: "/")
        guard path.count >= 4, path[2] == "pull", let number = Int(path[3]), number > 0,
              path[3].allSatisfy(\.isNumber),
              path.prefix(2).allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { return nil }
        let repo = "\(path[0])/\(path[1])"
        return (repo, number, "https://github.com/\(repo)/pull/\(number)")
    }

    private func pullRequestGH(_ arguments: [String], directory: String) throws -> [String: Any] {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env", arguments: ["gh"] + arguments,
            stdinText: "", currentDirectoryPath: directory, timeout: 15
        )
        guard !result.timedOut, result.status == 0 else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.pr.error.lookupFailed",
                defaultValue: "cmux pr could not resolve the pull request with gh; run gh auth status and try again"
            ))
        }
        guard let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw pullRequestMalformedMetadataError()
        }
        return object
    }

    private func pullRequestMalformedMetadataError() -> CLIError {
        CLIError(message: CMUXDiffViewerLocalization.string(
            "cli.pr.error.lookupMalformed",
            defaultValue: "cmux pr received invalid pull-request metadata from gh"
        ))
    }

    static let pullRequestUsage = CMUXDiffViewerLocalization.string(
        "cli.pr.usage",
        defaultValue: """
        Usage: cmux pr <url|number> [--workspace <id|ref|index>] [--window <id|ref|index>]
               cmux pr clear [--workspace <id|ref|index>] [--window <id|ref|index>]

        Attach or replace a GitHub PR link immediately. Requires git and authenticated gh.
        Uses the current directory's gh repository, including its configured fork upstream.
        Target: explicit workspace, caller TTY, CMUX_WORKSPACE_ID, then a unique worktree match.
        --window restricts resolution; ambiguous targets fail without changing focus.
        The manual link survives branch refreshes until replaced, cleared, or the session ends.
        The existing watcher refreshes matching PR status. Clear removes only the manual link.
        Sidebar visibility and click settings still apply.

        Example:
          url=$(gh pr create --fill) && cmux pr "$url"
          cmux pr 123
          cmux pr clear
        """
    )
}
