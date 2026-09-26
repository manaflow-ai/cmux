import CmuxFoundation
import Foundation

/// Explicit PR handoff from a script into the existing sidebar presentation.
extension CMUXCLI {
    func runPullRequestCommand(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?,
        jsonOutput: Bool
    ) async throws {
        let (workspaceArg, rest) = parseOption(commandArgs, name: "--workspace")
        let (windowArg, positional) = parseOption(rest, name: "--window")
        guard positional.count == 1,
              !positional[0].hasPrefix("-"),
              workspaceArg.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("-") }) ?? true,
              windowArg.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("-") }) ?? true else {
            throw CLIError(message: Self.pullRequestUsage)
        }
        let windowID = try normalizeWindowHandle(windowArg ?? windowOverride, client: client)
        let workspaceID = try await pullRequestWorkspaceID(workspaceArg, windowID: windowID, client: client)
        let selector = positional[0]
        var tokens = ["clear_workspace_pr", "--tab=\(workspaceID)"]
        var result: [String: Any] = ["workspace_id": workspaceID, "cleared": selector == "clear"]
        if selector != "clear" {
            let metadata = try await pullRequestMetadata(selector)
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
    /// An external script may match exactly one workspace in its own worktree,
    /// or, when none is there, exactly one in another worktree of the repository.
    /// Mutable foreground selection is never an implicit caller identity.
    private func pullRequestWorkspaceID(
        _ explicit: String?,
        windowID: String?,
        client: SocketClient
    ) async throws -> String {
        if let explicit {
            let id = try resolveWorkspaceId(explicit, client: client, windowHandle: windowID)
            if let windowID {
                let response = try client.sendV2(method: "system.identify", params: ["caller": ["workspace_id": id]])
                let caller = response["caller"] as? [String: Any]
                guard Self.pullRequestWindowIDsEqual(caller?["window_id"] as? String, windowID) else {
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
               windowID == nil || Self.pullRequestWindowIDsEqual(caller["window_id"] as? String, windowID) {
                ttyWorkspace = id
            }
        }
        if let ttyWorkspace { return ttyWorkspace }
        if windowID == nil, let raw = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try resolveWorkspaceId(raw, client: client)
        }
        let root = try await pullRequestRepositoryRoot()
        let windows = try client.sendV2(method: "window.list")["windows"] as? [[String: Any]] ?? []
        // Git's registered worktrees are the repository identity boundary. Read
        // them once so a linked worktree beside the current checkout remains a
        // valid target without probing every workspace with Git.
        let worktreeRoots = await pullRequestWorktreeRoots(root: root)
        // One invocation-local identity cache is shared by all workspace rows.
        // Repeated directories and common ancestors are resolved once.
        var normalizedPaths: [String: String] = [:]
        var pathMembership = Dictionary(uniqueKeysWithValues: worktreeRoots.map { ($0, true) })
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var candidates: [String: String] = [:]
        for window in windows {
            guard let id = window["id"] as? String,
                  windowID == nil || Self.pullRequestWindowIDsEqual(id, windowID) else { continue }
            let workspaces = try client.sendV2(method: "workspace.list", params: ["window_id": id])["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                guard let workspaceID = workspace["id"] as? String,
                      let directory = workspace["current_directory"] as? String,
                      directory.hasPrefix("/") || directory.hasPrefix("~"),
                      (workspace["remote"] as? [String: Any])?["enabled"] as? Bool != true else { continue }
                let path: String
                if let cached = normalizedPaths[directory] {
                    path = cached
                } else {
                    path = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                        .standardizedFileURL.resolvingSymlinksInPath().path
                    normalizedPaths[directory] = path
                }
                guard worktreeRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                guard try await pullRequestWorkspacePathIsCandidate(
                    path, worktreeRoots: worktreeRoots, membership: &pathMembership, deadline: deadline
                ) else { continue }
                candidates[workspaceID] = path
            }
        }
        // The caller's own checkout wins; a sibling worktree of the same
        // repository is only a fallback when no workspace sits in the caller's.
        let ownCandidates = candidates.filter {
            Self.pullRequestOwningWorktreeRoot($0.value, worktreeRoots: worktreeRoots) == root
        }
        let pool = ownCandidates.isEmpty ? candidates : ownCandidates
        guard pool.count == 1, let workspaceID = pool.keys.first else {
            throw pullRequestAmbiguousWorkspaceError()
        }
        return workspaceID
    }

    /// The deepest registered worktree containing `path`, so a worktree nested
    /// inside another checkout owns its own directories.
    private static func pullRequestOwningWorktreeRoot(_ path: String, worktreeRoots: [String]) -> String? {
        worktreeRoots
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
    }

    private func pullRequestAmbiguousWorkspaceError() -> CLIError {
        CLIError(message: CMUXDiffViewerLocalization.string(
            "cli.pr.error.ambiguousWorkspace",
            defaultValue: "cmux pr: could not identify the caller workspace; run it inside a cmux terminal or pass --workspace <id|ref|index>"
        ))
    }

    /// Reads the registered worktree roots once for the fallback scan. The
    /// current root remains a safe fallback when Git cannot enumerate them.
    private func pullRequestWorktreeRoots(root: String) async -> [String] {
        let result = await CommandRunner().run(
            directory: root,
            executable: "git",
            arguments: ["worktree", "list", "--porcelain"],
            timeout: 2
        )
        guard !result.timedOut, result.executionError == nil, result.exitStatus == 0 else {
            return [root]
        }
        let roots = result.stdout?.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("worktree ") else { return nil }
            return URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
                .standardizedFileURL.resolvingSymlinksInPath().path
        } ?? []
        var uniqueRoots: [String] = []
        var seen = Set<String>()
        for worktreeRoot in roots where seen.insert(worktreeRoot).inserted {
            uniqueRoots.append(worktreeRoot)
        }
        return uniqueRoots.isEmpty ? [root] : uniqueRoots
    }

    /// Memoizes membership by directory, including shared ancestors. A marker
    /// only triggers a Git identity probe; filenames never decide membership.
    /// The request-wide deadline bounds uncommon nested-repository probes.
    private func pullRequestWorkspacePathIsCandidate(
        _ path: String,
        worktreeRoots: [String],
        membership: inout [String: Bool],
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        if let cached = membership[path] { return cached }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw pullRequestAmbiguousWorkspaceError() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            membership[path] = false
            return false
        }
        guard let worktreeRoot = Self.pullRequestOwningWorktreeRoot(path, worktreeRoots: worktreeRoots) else {
            membership[path] = false
            return false
        }
        // A registered worktree root is already proven to belong to this
        // repository, including its .git file marker.
        if path == worktreeRoot {
            membership[path] = true
            return true
        }
        var cursor = path
        var visited: [String] = []
        var belongs = true
        while cursor == worktreeRoot || cursor.hasPrefix(worktreeRoot + "/") {
            if let cached = membership[cursor] {
                belongs = cached
                break
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw pullRequestAmbiguousWorkspaceError() }
            visited.append(cursor)
            let directory = URL(fileURLWithPath: cursor, isDirectory: true)
            // A bare repository has HEAD at its root; Git validates either
            // marker, including invalid .git artifacts and linked worktrees.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent("HEAD").path) {
                let result = await CommandRunner().run(
                    directory: cursor, executable: "git", arguments: ["rev-parse", "--show-toplevel"],
                    timeout: 2
                )
                try Task.checkCancellation()
                guard !result.timedOut, result.executionError == nil else {
                    // An incomplete scan cannot establish a unique target.
                    throw pullRequestAmbiguousWorkspaceError()
                }
                if result.exitStatus == 0, !result.timedOut, result.executionError == nil,
                   let output = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    let resolved = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath().path
                    belongs = worktreeRoots.contains(resolved)
                    break
                }
                // A malformed marker is not enough to establish a nested
                // repository boundary. Continue toward the registered root.
            }
            cursor = directory.deletingLastPathComponent().path
        }
        for directory in visited { membership[directory] = belongs }
        return belongs
    }

    private static func pullRequestWindowIDsEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if let lhsUUID = UUID(uuidString: lhs), let rhsUUID = UUID(uuidString: rhs) {
            return lhsUUID == rhsUUID
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func pullRequestRepositoryRoot() async throws -> String {
        let result = await CommandRunner().run(
            directory: FileManager.default.currentDirectoryPath,
            executable: "git", arguments: ["rev-parse", "--show-toplevel"], timeout: 10
        )
        let root = (result.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.timedOut, result.exitStatus == 0, result.executionError == nil, !root.isEmpty else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.pr.error.notRepository",
                defaultValue: "cmux pr requires a git repository in the current directory"
            ))
        }
        return URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func pullRequestMetadata(_ selector: String) async throws -> (number: Int, url: String, state: String, branch: String) {
        let numberToken = selector.hasPrefix("#") ? String(selector.dropFirst()) : selector
        let inputURL = pullRequestURL(selector)
        guard inputURL != nil || (Int(numberToken).map { $0 > 0 } == true && numberToken.allSatisfy(\.isNumber)) else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.pr.error.invalidSelector",
                defaultValue: "cmux pr expects a pull-request URL or a positive pull-request number"
            ))
        }
        let root = try await pullRequestRepositoryRoot()
        // gh owns fork/upstream/default-remote selection, just as it does for
        // the preceding gh pr create. Pin the resolved repository for the PR
        // lookup so an unrelated URL cannot select a different repository.
        let repoJSON = try await pullRequestGH(["repo", "view", "--json", "nameWithOwner,url,parent"], directory: root)
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
        var ghArguments = ["pr", "view", String(requestedNumber)]
        if inputURL != nil {
            ghArguments += ["--repo", requestedRepository]
        }
        ghArguments += ["--json", "number,url,state,headRefName"]
        let object = try await pullRequestGH(ghArguments, directory: root)
        guard let number = object["number"] as? Int, number == requestedNumber,
              let url = object["url"] as? String, let canonical = pullRequestURL(url),
              canonical.number == number,
              allowedRepositories.contains(canonical.repository.lowercased()),
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

    private func pullRequestGH(_ arguments: [String], directory: String) async throws -> [String: Any] {
        let result = await CommandRunner().run(
            directory: directory, executable: "gh", arguments: arguments, timeout: 15
        )
        guard !result.timedOut, result.exitStatus == 0, result.executionError == nil else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.pr.error.lookupFailed",
                defaultValue: "cmux pr could not resolve the pull request; check authentication and try again"
            ))
        }
        guard let data = result.stdout?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw pullRequestMalformedMetadataError()
        }
        return object
    }

    private func pullRequestMalformedMetadataError() -> CLIError {
        CLIError(message: CMUXDiffViewerLocalization.string(
            "cli.pr.error.lookupMalformed",
            defaultValue: "cmux pr received invalid pull-request information"
        ))
    }

    static let pullRequestUsage = CMUXDiffViewerLocalization.string(
        "cli.pr.usage",
        defaultValue: """
        Usage: cmux pr <url|number> [--workspace <id|ref|index>] [--window <id|ref|index>]
               cmux pr clear [--workspace <id|ref|index>] [--window <id|ref|index>]

        Attach or replace a pull-request link immediately. Requires a Git repository and account authentication.
        Uses the repository associated with the current directory, including its configured upstream.
        Target: explicit workspace, caller TTY, configured workspace, then a unique worktree match.
        --window restricts resolution; ambiguous targets fail without changing focus.
        The manual link survives branch refreshes until replaced, cleared, or the session ends.
        The existing watcher refreshes matching pull-request status. Clear removes only the manual link.
        Sidebar visibility and click settings still apply.

        Example:
          cmux pr 123
          cmux pr clear
        """
    )
}
