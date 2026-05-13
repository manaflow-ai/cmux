import Darwin
import Foundation

extension CMUXCLI {
    private nonisolated struct CmuxUseOptions {
        let repositoryArg: String
        let commandMode: CmuxUseCommandMode
    }

    private nonisolated enum CmuxUseCommandMode {
        case automatic
        case override(String)
        case none

        var shouldRunCommands: Bool {
            switch self {
            case .automatic, .override:
                return true
            case .none:
                return false
            }
        }
    }

    private struct CmuxUseCheckoutResult {
        let url: URL
        let action: String
    }

    private struct CmuxUseInstallResult {
        let url: URL
        let action: String
        let mode: String
    }

    private func parseUseOptions(_ commandArgs: [String]) throws -> CmuxUseOptions {
        var repositoryArg: String?
        var commandMode = CmuxUseCommandMode.automatic
        var index = 0

        while index < commandArgs.count {
            let arg = commandArgs[index]
            switch arg {
            case "--command":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "cmux use: --command requires a value")
                }
                let command = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else {
                    throw CLIError(message: "cmux use: --command requires a non-empty value")
                }
                if case .none = commandMode {
                    throw CLIError(message: "cmux use: --command cannot be used with --no-run")
                }
                commandMode = .override(command)
                index += 2
            case "--no-run":
                if case .override = commandMode {
                    throw CLIError(message: "cmux use: --command cannot be used with --no-run")
                }
                commandMode = .none
                index += 1
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "cmux use: unknown flag '\(arg)'. Known flags: --command <cmd>, --no-run")
                }
                if repositoryArg == nil {
                    repositoryArg = arg
                    index += 1
                } else {
                    throw CLIError(message: "cmux use: unexpected argument '\(arg)'")
                }
            }
        }

        guard let repositoryArg,
              !repositoryArg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "Usage: cmux use <owner/repo|github-url> [--command <cmd>] [--no-run]")
        }

        return CmuxUseOptions(
            repositoryArg: repositoryArg,
            commandMode: commandMode
        )
    }

    func runUse(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let options = try parseUseOptions(commandArgs)
        let repository = try CmuxUseSupport.parseGitHubRepository(options.repositoryArg)
        let checkoutURL = try CmuxUseSupport.managedSourceCheckoutURL(for: repository)
        let sourceCheckout = try ensureUseCheckout(repository: repository, checkoutURL: checkoutURL)
        let manifest = try CmuxUseSupport.loadManifest(in: sourceCheckout.url, repository: repository)
            ?? CmuxUseSupport.generateManifest(in: sourceCheckout.url, repository: repository)
        let checkout: CmuxUseCheckoutResult
        if manifest.installPath != nil {
            checkout = try ensureUseCheckout(
                repository: repository,
                checkoutURL: CmuxUseSupport.manifestInstallURL(for: manifest)
            )
        } else {
            checkout = sourceCheckout
        }

        let install: CmuxUseInstallResult
        if manifest.generated {
            install = CmuxUseInstallResult(
                url: checkout.url,
                action: checkout.action,
                mode: manifest.installPath == nil ? "generated-workspace" : "generated-path"
            )
        } else if manifest.installPath != nil {
            install = CmuxUseInstallResult(url: checkout.url, action: checkout.action, mode: "manifest-path")
        } else {
            let installed = try installManifestExtension(checkoutURL: checkout.url, manifest: manifest)
            install = CmuxUseInstallResult(url: installed.url, action: installed.action, mode: "manifest")
        }
        let generatedManifestURL: URL?
        if manifest.generated {
            generatedManifestURL = try CmuxUseSupport.writeGeneratedManifest(manifest, repository: repository)
        } else {
            generatedManifestURL = nil
        }
        if options.commandMode.shouldRunCommands, let installCommand = manifest.installCommand {
            try runUseInstallCommand(installCommand, cwd: install.url, jsonOutput: jsonOutput)
        }

        let detectedCommand: CmuxUseLaunchCommand?
        switch options.commandMode {
        case .automatic:
            detectedCommand = try CmuxUseSupport.detectLaunchCommand(in: install.url, manifest: manifest)
        case .override(let commandOverride):
            detectedCommand = CmuxUseLaunchCommand(command: commandOverride, source: "--command")
        case .none:
            detectedCommand = nil
        }
        let initialCommand = try detectedCommand.map { try writeUseLaunchCommandScript($0.command) }

        try withUseSocketClient(socketPath: socketPath, explicitPassword: explicitPassword) { client, launched in
            var initialEnv: [String: String] = [
                "CMUX_EXTENSION_REPOSITORY": repository.fullName,
                "CMUX_EXTENSION_URL": repository.webURL,
                "CMUX_EXTENSION_DIR": install.url.path,
                "CMUX_EXTENSION_MODE": install.mode,
                "CMUX_USE_REPOSITORY": repository.fullName,
            ]
            initialEnv["CMUX_EXTENSION_ID"] = manifest.id
            initialEnv["CMUX_EXTENSION_NAME"] = manifest.name
            initialEnv["CMUX_EXTENSION_PUBLISHER"] = manifest.publisher
            initialEnv["CMUX_EXTENSION_VERSION"] = manifest.version

            var params: [String: Any] = [
                "cwd": install.url.path,
                "title": manifest.name,
                "description": "cmux extension: \(repository.fullName)",
                "initial_env": initialEnv,
            ]
            if let windowOverride,
               let normalizedWindow = try normalizeWindowHandle(windowOverride, client: client) {
                params["window_id"] = normalizedWindow
            }
            if let initialCommand {
                params["initial_command"] = initialCommand
            }

            let response = try client.sendV2(method: "workspace.create", params: params)
            let formattedResponse = formatIDs(response, mode: idFormat) as? [String: Any] ?? response
            let workspaceHandle = (formattedResponse["workspace_ref"] as? String)
                ?? (formattedResponse["workspace_id"] as? String)
                ?? (response["workspace_ref"] as? String)
                ?? (response["workspace_id"] as? String)
            guard let workspaceHandle, !workspaceHandle.isEmpty else {
                throw CLIError(message: "workspace.create did not return workspace_id or workspace_ref")
            }

            if jsonOutput {
                var payload: [String: Any] = formattedResponse
                payload["repository"] = repository.fullName
                payload["repository_url"] = repository.webURL
                payload["path"] = install.url.path
                payload["source_path"] = sourceCheckout.url.path
                payload["install_action"] = install.action
                payload["install_mode"] = install.mode
                payload["launched_app"] = launched
                payload["extension_id"] = manifest.id
                payload["extension_name"] = manifest.name
                payload["extension_publisher"] = manifest.publisher
                payload["extension_version"] = manifest.version
                payload["manifest"] = manifest.sourceFile
                payload["manifest_generated"] = manifest.generated
                if let generatedManifestURL {
                    payload["generated_manifest_path"] = generatedManifestURL.path
                }
                if let detectedCommand {
                    payload["command"] = detectedCommand.command
                    payload["command_source"] = detectedCommand.source
                } else {
                    payload["command"] = NSNull()
                    payload["command_source"] = NSNull()
                }
                print(jsonString(payload))
                return
            }

            print("OK \(workspaceHandle)")
            print("Repository: \(repository.fullName)")
            print("Mode: \(install.mode)")
            print("Extension: \(manifest.id) \(manifest.version)")
            print("Manifest: \(manifest.sourceFile)")
            if let generatedManifestURL {
                print("Generated manifest: \(generatedManifestURL.path)")
            }
            print("Path: \(install.url.path)")
            print("Source: \(sourceCheckout.url.path)")
            print("Install: \(install.action)")
            if let detectedCommand {
                print("Command: \(detectedCommand.command)")
                print("Detected: \(detectedCommand.source)")
            } else {
                print("Command: none detected; workspace opened at the checkout")
            }
        }
    }

    private func installManifestExtension(
        checkoutURL: URL,
        manifest: CmuxUseManifest
    ) throws -> CmuxUseCheckoutResult {
        let fm = FileManager.default
        let installURL = try CmuxUseSupport.manifestInstallURL(for: manifest)
        let parentURL = installURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)

        let existed = fm.fileExists(atPath: installURL.path)
        let tempURL = parentURL.appendingPathComponent(".\(manifest.version).tmp.\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempURL) }

        try fm.copyItem(at: checkoutURL, to: tempURL)
        try? fm.removeItem(at: tempURL.appendingPathComponent(".git", isDirectory: true))

        var backupURLToFinalize: URL?
        var shouldFinalizeBackup = true
        defer {
            if shouldFinalizeBackup, let backupURL = backupURLToFinalize {
                if fm.fileExists(atPath: installURL.path) {
                    try? fm.removeItem(at: backupURL)
                } else if fm.fileExists(atPath: backupURL.path) {
                    try? fm.moveItem(at: backupURL, to: installURL)
                }
            }
        }

        if existed {
            let backupURL = parentURL.appendingPathComponent(".\(manifest.version).previous.\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: installURL, to: backupURL)
            backupURLToFinalize = backupURL
            do {
                try fm.moveItem(at: tempURL, to: installURL)
            } catch {
                let installError = error
                if !fm.fileExists(atPath: installURL.path),
                   fm.fileExists(atPath: backupURL.path) {
                    do {
                        try fm.moveItem(at: backupURL, to: installURL)
                    } catch {
                        shouldFinalizeBackup = false
                        let message = "Failed to replace extension at \(installURL.path): \(installError.localizedDescription). "
                            + "Previous installation remains at \(backupURL.path) because restore failed: \(error.localizedDescription)"
                        throw CLIError(message: message)
                    }
                }
                throw installError
            }
        } else {
            try fm.moveItem(at: tempURL, to: installURL)
        }
        return CmuxUseCheckoutResult(url: installURL, action: existed ? "reinstalled" : "installed")
    }

    private func runUseInstallCommand(_ command: String, cwd: URL, jsonOutput: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd

        process.standardOutput = jsonOutput ? FileHandle.standardError : FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError(message: "cmux use install command failed: exit \(process.terminationStatus)")
        }
    }

    private func writeUseLaunchCommandScript(_ command: String) throws -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw CLIError(message: "cmux use launch command is empty")
        }

        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-use-launch-\(UUID().uuidString.lowercased()).sh",
            isDirectory: false
        )
        let encodedCommand = shellQuote(Data(trimmedCommand.utf8).base64EncodedString())
        let script = """
        #!/bin/sh
        if ! cmux_use_command="$(printf %s \(encodedCommand) | base64 -d 2>/dev/null || printf %s \(encodedCommand) | base64 -D 2>/dev/null)"; then
          printf '\\n[cmux] failed to decode launch command; starting a shell.\\n' >&2 || true
          rm -f -- "$0" 2>/dev/null || true
          exec "${SHELL:-/bin/zsh}" -l
        fi
        rm -f -- "$0" 2>/dev/null || true
        /bin/zsh -lc "$cmux_use_command"
        cmux_use_status=$?
        printf '\\n[cmux] command exited with status %s; starting a shell.\\n' "$cmux_use_status" >&2 || true
        unset cmux_use_command cmux_use_status
        exec "${SHELL:-/bin/zsh}" -l
        """
        try script.appending("\n").write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return shellQuote(scriptURL.path)
    }

    private func ensureUseCheckout(
        repository: CmuxUseRepository,
        checkoutURL: URL
    ) throws -> CmuxUseCheckoutResult {
        let gitPath = try resolveGitExecutable()
        let fm = FileManager.default
        let parentURL = checkoutURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)

        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: checkoutURL.path, isDirectory: &isDirectory)
        if !exists {
            let result = CLIProcessRunner.runProcess(
                executablePath: gitPath,
                arguments: ["clone", repository.cloneURL, checkoutURL.path]
            )
            guard result.status == 0 else {
                throw CLIError(message: "git clone failed: \(trimmedProcessError(result))")
            }
            return CmuxUseCheckoutResult(url: checkoutURL, action: "cloned")
        }

        guard isDirectory.boolValue else {
            throw CLIError(message: "Extension checkout path exists and is not a directory: \(checkoutURL.path)")
        }

        let gitDirectoryURL = checkoutURL.appendingPathComponent(".git", isDirectory: true)
        guard fm.fileExists(atPath: gitDirectoryURL.path) else {
            throw CLIError(message: "Extension checkout exists but is not a git repository: \(checkoutURL.path)")
        }

        let remoteResult = CLIProcessRunner.runProcess(
            executablePath: gitPath,
            arguments: ["-C", checkoutURL.path, "remote", "get-url", "origin"]
        )
        guard remoteResult.status == 0 else {
            throw CLIError(message: "git remote get-url origin failed: \(trimmedProcessError(remoteResult))")
        }
        let remoteURL = remoteResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CmuxUseSupport.gitRemote(remoteURL, matches: repository) else {
            throw CLIError(message: "Existing checkout origin '\(remoteURL)' does not match \(repository.cloneURL)")
        }

        let pullResult = CLIProcessRunner.runProcess(
            executablePath: gitPath,
            arguments: ["-C", checkoutURL.path, "pull", "--ff-only"]
        )
        guard pullResult.status == 0 else {
            throw CLIError(message: "git pull --ff-only failed: \(trimmedProcessError(pullResult))")
        }
        return CmuxUseCheckoutResult(url: checkoutURL, action: "updated")
    }

    private func resolveGitExecutable() throws -> String {
        if let gitPath = resolveExecutableInPath("git") {
            return gitPath
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            return "/usr/bin/git"
        }
        throw CLIError(message: "cmux use requires git in PATH")
    }

    private func trimmedProcessError(_ result: CLIProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }
        return "exit \(result.status)"
    }

    private func withUseSocketClient<T>(
        socketPath: String,
        explicitPassword: String?,
        _ body: (SocketClient, Bool) throws -> T
    ) throws -> T {
        let client = SocketClient(path: socketPath)
        do {
            try client.connect()
        } catch {
            client.close()
            guard shouldLaunchAppAfterSocketConnectFailure(socketPath: socketPath) else {
                throw CLIError(message: "Failed to connect to cmux socket at \(socketPath): \(error)")
            }

            return try withLaunchedUseSocketClient(
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                body
            )
        }

        defer { client.close() }
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath,
            allowV2Fallback: true
        )
        return try body(client, false)
    }

    private func withLaunchedUseSocketClient<T>(
        socketPath: String,
        explicitPassword: String?,
        _ body: (SocketClient, Bool) throws -> T
    ) throws -> T {
        try launchApp(strictOpenExit: true)
        let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
        defer { launchedClient.close() }
        try authenticateClientIfNeeded(
            launchedClient,
            explicitPassword: explicitPassword,
            socketPath: socketPath,
            allowV2Fallback: true
        )
        return try body(launchedClient, true)
    }

    private func shouldLaunchAppAfterSocketConnectFailure(socketPath: String) -> Bool {
        guard socketPath.hasPrefix("/") else {
            return false
        }

        var metadata = stat()
        guard stat(socketPath, &metadata) == 0 else {
            return true
        }

        let fileType = metadata.st_mode & mode_t(S_IFMT)
        return fileType == mode_t(S_IFSOCK) && metadata.st_uid == getuid()
    }
}
