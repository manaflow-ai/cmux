import Foundation

/// Process selection and launch for the portable diff-viewer backend.
extension CMUXCLI {
    func fetchDiffURLToFile(_ url: URL, directory: URL) throws -> URL {
        let maximumBytes = 512 * 1024 * 1024
        let outputURL = directory.appendingPathComponent("download-\(UUID().uuidString).patch")
        var keepOutput = false
        defer {
            if !keepOutput {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "curl", "-fL", "--silent", "--show-error", "--max-time", "120",
                "--max-filesize", String(maximumBytes),
                "--output", outputURL.path, url.absoluteString,
            ],
            timeout: 130
        )
        guard !result.timedOut, result.status == 0 else {
            let reason = result.timedOut ? "Timed out fetching" : "Failed to fetch"
            throw CLIError(message: "\(reason) diff URL: \(url.absoluteString)")
        }
        guard let fileSize = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize > 0 else {
            throw CLIError(message: "Diff input is empty: \(url.absoluteString)")
        }
        guard fileSize <= maximumBytes else {
            throw CLIError(message: "Diff input exceeds 512 MiB: \(url.absoluteString)")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        keepOutput = true
        return outputURL
    }

    /// Navigates a deferred custom-scheme viewer after Git work replaces its placeholder.
    func navigateCompletedDiffViewerIfNeeded(
        _ wasDeferred: Bool,
        _ scheme: String?,
        _ payload: [String: Any],
        _ expectedURL: URL,
        _ completedURL: URL,
        _ socketPath: String,
        _ explicitPassword: String?
    ) throws {
        guard wasDeferred, scheme == "cmux-diff-viewer" else { return }
        guard let surface = (payload["surface_id"] as? String) ?? (payload["surface_ref"] as? String) else {
            throw CLIError(message: "Deferred diff viewer response is missing its surface")
        }
        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: false
        )
        defer { client.close() }
        _ = try client.sendV2(
            method: "browser.navigate",
            params: [
                "surface_id": surface,
                "url": completedURL.absoluteString,
                "expected_url": expectedURL.absoluteString,
            ]
        )
    }

    func startDiffViewerHTTPServer(rootDirectory: URL, runtime: URL? = nil) throws -> URL {
        guard let cmuxExecutableURL = diffViewerExecutableURL(for: runtime),
              let executableURL = diffViewerServerExecutableURL(for: runtime) else {
            throw CLIError(message: "Failed to resolve cmux executable for diff viewer server")
        }

        let process = Process()
        process.executableURL = executableURL
        if executableURL == cmuxExecutableURL {
            process.arguments = ["diff-viewer-server", "--root", rootDirectory.path]
        } else {
            process.arguments = [
                "serve",
                "--root", rootDirectory.path,
                "--cmux", cmuxExecutableURL.path,
            ]
        }
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        if let nullInput = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = nullInput
        }
        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = nullOutput
        }

        do {
            try process.run()
        } catch {
            throw CLIError(message: "Failed to start diff viewer server: \(error.localizedDescription)")
        }

        let port = try readDiffViewerHTTPServerPort(
            from: stdoutPipe.fileHandleForReading,
            process: process
        )
        guard diffViewerHTTPServerIsReachable(port: port) else {
            process.terminate()
            throw CLIError(message: "Diff viewer server did not become reachable")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw CLIError(message: "Failed to build diff viewer server URL")
        }
        return url
    }

    func diffViewerServerExecutableURL(for runtime: URL?) -> URL? {
        guard let cmuxExecutable = diffViewerExecutableURL(for: runtime) else { return nil }
        let sidecar = cmuxExecutable.deletingLastPathComponent()
            .appendingPathComponent("cmux-diff-sidecar", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: sidecar.path) {
            return sidecar.standardizedFileURL.resolvingSymlinksInPath()
        }
        return cmuxExecutable
    }

    func diffViewerUsesTypedSidecar(runtime: URL?) -> Bool {
        guard let selected = diffViewerServerExecutableURL(for: runtime),
              let legacy = diffViewerExecutableURL(for: runtime) else {
            return false
        }
        return selected.standardizedFileURL.resolvingSymlinksInPath().path
            != legacy.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func diffSessionSourcePayload(
        source: DiffSource,
        context: DiffSourceContext
    ) -> [String: Any]? {
        guard let repoRoot = context.repoRoot else { return nil }
        switch source {
        case .unstaged:
            return ["kind": "unstaged", "repoRoot": repoRoot]
        case .staged:
            return ["kind": "staged", "repoRoot": repoRoot]
        case .branch:
            guard let baseRef = context.branchBaseRef, !baseRef.isEmpty else { return nil }
            return ["kind": "branch", "repoRoot": repoRoot, "baseRef": baseRef]
        case .lastTurn:
            return nil
        }
    }

    func diffViewerBundledAssetDirectory(runtime: URL? = nil) throws -> URL {
        if let directory = diffViewerBundledAssetDirectoryCandidates(runtime: runtime).first {
            return directory
        }
        throw CLIError(message: "Bundled diff viewer assets not found")
    }

    private func diffViewerBundledAssetDirectoryCandidates(runtime: URL? = nil) -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        var seen: Set<String> = []

        func appendIfExisting(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            guard (try? diffViewerBundledAssetFileURL(relativePath: "diffs.mjs", in: standardized)) != nil,
                  (try? diffViewerBundledAssetFileURL(relativePath: "trees.mjs", in: standardized)) != nil else {
                return
            }
            candidates.append(standardized)
        }

        if let executableURL = diffViewerExecutableURL(for: runtime) {
            let execDir = executableURL.deletingLastPathComponent().standardizedFileURL
            for relativePath in [
                "markdown-viewer/diff-viewer",
                "../markdown-viewer/diff-viewer",
                "../../Resources/markdown-viewer/diff-viewer",
                "../../../Contents/Resources/markdown-viewer/diff-viewer"
            ] {
                appendIfExisting(execDir.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL)
            }

            var current = execDir
            for _ in 0..<6 {
                if current.pathExtension == "app" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("Contents", isDirectory: true)
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("markdown-viewer", isDirectory: true)
                            .appendingPathComponent("diff-viewer", isDirectory: true)
                    )
                    break
                }
                let projectMarker = current.appendingPathComponent("cmux.xcodeproj/project.pbxproj", isDirectory: false)
                let repoAssetDirectory = current
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("markdown-viewer", isDirectory: true)
                    .appendingPathComponent("diff-viewer", isDirectory: true)
                if fileManager.fileExists(atPath: projectMarker.path) {
                    appendIfExisting(repoAssetDirectory)
                    break
                }
                current = current.deletingLastPathComponent().standardizedFileURL
            }
        }

        appendIfExisting(
            Bundle.main.resourceURL?
                .appendingPathComponent("markdown-viewer", isDirectory: true)
                .appendingPathComponent("diff-viewer", isDirectory: true)
        )

        let devRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("diff-viewer", isDirectory: true)
        appendIfExisting(devRelative)
        return candidates
    }
}
