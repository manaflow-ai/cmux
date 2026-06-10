import Darwin
import Foundation


// MARK: - Diff Source Canonicalization and Input Reading
extension CMUXCLI {
    func canonicalFileURL(_ url: URL) -> URL {
        if let resolvedPath = realpath(url.path, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
        }
        return url.standardizedFileURL
    }

    func canonicalDiffSourceContext(
        workspaceHandle: String?,
        surfaceHandle: String?,
        windowHandle: String?,
        client: SocketClient
    ) throws -> DiffSourceContext {
        let workspaceId = try canonicalDiffWorkspaceId(
            workspaceHandle,
            windowHandle: windowHandle,
            client: client
        )
        let surfaceId = try canonicalDiffSurfaceId(
            surfaceHandle,
            workspaceId: workspaceId,
            windowHandle: windowHandle,
            client: client
        )
        return DiffSourceContext(workspaceId: workspaceId, surfaceId: surfaceId, repoRoot: nil, branchBaseRef: nil)
    }

    private func canonicalDiffWorkspaceId(
        _ workspaceHandle: String?,
        windowHandle: String?,
        client: SocketClient
    ) throws -> String? {
        guard let workspaceHandle = normalizedDiffSourceValue(workspaceHandle) else {
            return nil
        }
        if UUID(uuidString: workspaceHandle) != nil {
            return workspaceHandle
        }

        var params: [String: Any] = [:]
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        if let matched = try matchingDiffWorkspaceId(workspaceHandle, params: params, client: client) {
            return matched
        }

        if windowHandle == nil {
            let listed = try client.sendV2(method: "window.list")
            let windows = listed["windows"] as? [[String: Any]] ?? []
            for window in windows {
                guard let listedWindowHandle = (window["id"] as? String) ?? (window["ref"] as? String) else {
                    continue
                }
                if let matched = try matchingDiffWorkspaceId(
                    workspaceHandle,
                    params: ["window_id": listedWindowHandle],
                    client: client
                ) {
                    return matched
                }
            }
        }

        throw CLIError(message: "Workspace not found: \(workspaceHandle)")
    }

    private func canonicalDiffSurfaceId(
        _ surfaceHandle: String?,
        workspaceId: String?,
        windowHandle: String?,
        client: SocketClient
    ) throws -> String? {
        guard let surfaceHandle = normalizedDiffSourceValue(surfaceHandle) else {
            return nil
        }
        if UUID(uuidString: surfaceHandle) != nil {
            return surfaceHandle
        }

        var params: [String: Any] = [:]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        let listed = try client.sendV2(method: "surface.list", params: params)
        let surfaces = listed["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces where diffHandle(surfaceHandle, matches: surface) {
            return (surface["id"] as? String) ?? (surface["ref"] as? String) ?? surfaceHandle
        }
        throw CLIError(message: "Surface not found: \(surfaceHandle)")
    }

    private func matchingDiffWorkspaceId(
        _ workspaceHandle: String,
        params: [String: Any],
        client: SocketClient
    ) throws -> String? {
        let listed = try client.sendV2(method: "workspace.list", params: params)
        let workspaces = listed["workspaces"] as? [[String: Any]] ?? []
        for workspace in workspaces where diffHandle(workspaceHandle, matches: workspace) {
            return (workspace["id"] as? String) ?? (workspace["ref"] as? String) ?? workspaceHandle
        }
        return nil
    }

    private func diffHandle(_ handle: String, matches item: [String: Any]) -> Bool {
        guard let target = normalizedDiffSourceValue(handle) else {
            return false
        }
        for candidate in [item["id"] as? String, item["ref"] as? String] {
            guard let candidate = normalizedDiffSourceValue(candidate) else {
                continue
            }
            if let targetUUID = UUID(uuidString: target),
               let candidateUUID = UUID(uuidString: candidate) {
                if targetUUID == candidateUUID {
                    return true
                }
            } else if target.lowercased() == candidate.lowercased() {
                return true
            }
        }
        return false
    }

    func readDiffInput(
        _ rawInput: String?,
        source: DiffSource?,
        context: DiffSourceContext
    ) throws -> DiffInput {
        if let source {
            return try readGitDiffInput(source: source, context: context)
        }

        guard let rawInput, rawInput != "-" else {
            guard isatty(STDIN_FILENO) == 0 else {
                throw CLIError(message: "diff requires a patch file, piped stdin, or a git source. Usage: cmux diff <patch-file>|-|--unstaged|--staged|--branch|--last-turn")
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return DiffInput(
                patch: try decodeDiffData(data, sourceDescription: "stdin"),
                sourceLabel: "stdin",
                defaultTitle: "cmux diff",
                emptyMessage: nil,
                externalURL: nil
            )
        }

        if let trustedRemoteURL = diffInputTrustedRemotePatchURL(rawInput) {
            let sourceURL = URL(string: rawInput) ?? trustedRemoteURL
            if diffViewerShouldStreamRemotePatch() {
                return DiffInput(
                    patch: "",
                    sourceLabel: sourceURL.absoluteString,
                    defaultTitle: diffInputURLTitle(sourceURL),
                    emptyMessage: nil,
                    externalURL: diffInputExternalURL(sourceURL).absoluteString,
                    remotePatchURL: trustedRemoteURL
                )
            }
            do {
                return DiffInput(
                    patch: try fetchDiffURL(trustedRemoteURL),
                    sourceLabel: sourceURL.absoluteString,
                    defaultTitle: diffInputURLTitle(sourceURL),
                    emptyMessage: nil,
                    externalURL: diffInputExternalURL(sourceURL).absoluteString
                )
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError(message: "Failed to fetch diff URL: \(trustedRemoteURL.absoluteString)")
            }
        }

        if let url = diffInputPatchURL(rawInput) {
            let sourceURL = URL(string: rawInput) ?? url
            do {
                return DiffInput(
                    patch: try fetchDiffURL(url),
                    sourceLabel: sourceURL.absoluteString,
                    defaultTitle: diffInputURLTitle(sourceURL),
                    emptyMessage: nil,
                    externalURL: diffInputExternalURL(sourceURL).absoluteString
                )
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError(message: "Failed to fetch diff URL: \(url.absoluteString)")
            }
        }

        let resolved = resolvePath(rawInput)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }
        guard !isDir.boolValue else {
            throw CLIError(message: "Path is a directory, not a patch file: \(resolved)")
        }
        guard FileManager.default.isReadableFile(atPath: resolved) else {
            throw CLIError(message: "File not readable: \(resolved)")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let filename = URL(fileURLWithPath: resolved).lastPathComponent
        return DiffInput(
            patch: try decodeDiffData(data, sourceDescription: resolved),
            sourceLabel: resolved,
            defaultTitle: filename.isEmpty ? "cmux diff" : filename,
            emptyMessage: nil,
            externalURL: nil
        )
    }

    private func diffViewerShouldStreamRemotePatch() -> Bool {
        let value = ProcessInfo.processInfo.environment["CMUX_DIFF_VIEWER_STREAM_REMOTE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    func readGitDiffInput(source: DiffSource, context: DiffSourceContext) throws -> DiffInput {
        let repoRoot = try gitRepoRootForDiff(context)
        let patch: String
        let sourceLabel: String
        switch source {
        case .unstaged:
            patch = try gitStdout(gitDiffPatchArguments(["--"]), in: repoRoot)
            sourceLabel = "git unstaged"
        case .staged:
            patch = try gitStdout(gitDiffPatchArguments(["--cached", "--"]), in: repoRoot)
            sourceLabel = "git staged"
        case .branch:
            let baseRef = try resolvedGitBranchDiffBaseRef(context.branchBaseRef, in: repoRoot)
            let mergeBase = try gitSingleLine(["merge-base", "HEAD", baseRef], in: repoRoot)
            patch = try gitStdout(gitDiffPatchArguments([mergeBase, "--"]), in: repoRoot)
            sourceLabel = "git branch \(baseRef)"
        case .lastTurn:
            guard let workspaceId = normalizedDiffSourceValue(context.workspaceId),
                  let surfaceId = normalizedDiffSourceValue(context.surfaceId) else {
                throw CLIError(message: "cmux diff --last-turn requires a workspace and surface context. Run it from a cmux terminal or pass --workspace and --surface.")
            }
            let env = ProcessInfo.processInfo.environment
            let baselineStorePath = CMUXAgentTurnDiffBaselineFile.path(env: env)
            if let record = try latestAgentTurnDiffBaseline(
                repoRoot: repoRoot,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                env: env
            ) {
                _ = try gitStdout(["cat-file", "-e", "\(record.baseCommit)^{tree}"], in: repoRoot)
                patch = try joinedGitDiffPatches([
                    gitStdout(gitDiffPatchArguments([record.baseCommit, "--"]), in: repoRoot),
                    gitUntrackedPatchSinceBaseline(record: record, in: repoRoot, storePath: baselineStorePath)
                ])
            } else {
                // No last-turn baseline recorded yet: emit an empty patch so the
                // viewer renders the friendly empty diff state (with the source
                // switcher) instead of throwing a developer-facing CLI error.
                patch = ""
            }
            sourceLabel = "git last-turn \(workspaceId) \(surfaceId)"
        }
        return DiffInput(
            patch: patch,
            sourceLabel: sourceLabel,
            defaultTitle: source.title,
            emptyMessage: source.emptyMessage,
            externalURL: nil
        )
    }

    private func diffInputPatchURL(_ rawInput: String) -> URL? {
        guard let url = URL(string: rawInput),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return nil
        }

        if host == "diffshub.com" || host == "www.diffshub.com" {
            let components = url.pathComponents
            if components.count >= 5,
               components[3] == "pull",
               Int(components[4]) != nil {
                return URL(string: "https://github.com/\(components[1])/\(components[2])/pull/\(components[4]).diff")
            }
        }

        if host == "github.com" || host == "www.github.com" {
            let components = url.pathComponents
            if components.count >= 5,
               components[3] == "pull",
               Int(components[4].replacingOccurrences(of: ".patch", with: "").replacingOccurrences(of: ".diff", with: "")) != nil {
                let pullComponent = components[4]
                if pullComponent.hasSuffix(".patch") || pullComponent.hasSuffix(".diff") {
                    return url
                }
                return URL(string: "https://github.com/\(components[1])/\(components[2])/pull/\(pullComponent).diff")
            }
        }

        return url
    }

    func diffInputTrustedRemotePatchURL(_ rawInput: String) -> URL? {
        guard let url = URL(string: rawInput),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }

        if host == "diffshub.com" || host == "www.diffshub.com" {
            let components = url.pathComponents
            guard components.count >= 5,
                  components[3] == "pull" else {
                return nil
            }
            return trustedGitHubPullPatchURL(
                owner: components[1],
                repo: components[2],
                pullComponent: components[4],
                defaultExtension: "diff"
            )
        }

        if host == "github.com" || host == "www.github.com" {
            let components = url.pathComponents
            guard components.count >= 5,
                  components[3] == "pull" else {
                return nil
            }
            return trustedGitHubPullPatchURL(
                owner: components[1],
                repo: components[2],
                pullComponent: components[4],
                defaultExtension: "diff"
            )
        }

        return nil
    }

    private func trustedGitHubPullPatchURL(
        owner: String,
        repo: String,
        pullComponent: String,
        defaultExtension: String
    ) -> URL? {
        guard githubPathSegmentIsSafe(owner),
              githubPathSegmentIsSafe(repo) else {
            return nil
        }

        let suffix: String
        let pullNumber: String
        if pullComponent.hasSuffix(".patch") {
            suffix = "patch"
            pullNumber = String(pullComponent.dropLast(".patch".count))
        } else if pullComponent.hasSuffix(".diff") {
            suffix = "diff"
            pullNumber = String(pullComponent.dropLast(".diff".count))
        } else {
            suffix = defaultExtension
            pullNumber = pullComponent
        }
        guard suffix == "diff" || suffix == "patch",
              pullNumber.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              Int(pullNumber).map({ $0 > 0 }) == true else {
            return nil
        }
        return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(pullNumber).\(suffix)")
    }

    private func githubPathSegmentIsSafe(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 65 && scalar.value <= 90) ||
                (scalar.value >= 97 && scalar.value <= 122) ||
                scalar == "-" ||
                scalar == "_" ||
                scalar == "."
        }
    }

    private func diffInputExternalURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return url
        }
        var components = url.pathComponents
        guard components.count >= 5,
              components[3] == "pull" else {
            return url
        }
        components[4] = components[4]
            .replacingOccurrences(of: ".patch", with: "")
            .replacingOccurrences(of: ".diff", with: "")
        var normalized = URLComponents(url: url, resolvingAgainstBaseURL: false)
        normalized?.path = components.joined(separator: "/").replacingOccurrences(of: "//", with: "/")
        normalized?.query = nil
        normalized?.fragment = nil
        return normalized?.url ?? url
    }

    private func fetchDiffURL(_ url: URL) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "curl",
                "-fL",
                "--silent",
                "--show-error",
                "--max-time", "120",
                url.absoluteString
            ],
            timeout: 130
        )
        if result.timedOut {
            throw CLIError(message: "Timed out fetching diff URL: \(url.absoluteString)")
        }
        guard result.status == 0 else {
            throw CLIError(message: "Failed to fetch diff URL: \(url.absoluteString)")
        }
        return result.stdout
    }

    private func diffInputURLTitle(_ url: URL) -> String {
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty {
            return last
        }
        return url.host ?? "cmux diff"
    }

    private func decodeDiffData(_ data: Data, sourceDescription: String) throws -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .ascii) {
            return text
        }
        throw CLIError(message: "Diff input is not valid UTF-8: \(sourceDescription)")
    }

}
