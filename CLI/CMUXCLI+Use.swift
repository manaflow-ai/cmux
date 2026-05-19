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

    private func parseUseOptions(_ commandArgs: [String]) throws -> CmuxUseOptions {
        var repositoryArg: String?
        var commandMode = CmuxUseCommandMode.automatic
        var index = 0

        while index < commandArgs.count {
            let arg = commandArgs[index]
            switch arg {
            case "--command":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: String(
                        localized: "cli.use.error.commandRequiresValue",
                        defaultValue: "cmux use: --command requires a value"
                    ))
                }
                let command = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else {
                    throw CLIError(message: String(
                        localized: "cli.use.error.commandRequiresNonEmptyValue",
                        defaultValue: "cmux use: --command requires a non-empty value"
                    ))
                }
                guard !command.hasPrefix("--") else {
                    throw CLIError(message: String(
                        localized: "cli.use.error.commandValueCannotBeFlag",
                        defaultValue: "cmux use: --command requires a command, not another flag"
                    ))
                }
                if case .none = commandMode {
                    throw CLIError(message: String(
                        localized: "cli.use.error.commandCannotCombineNoRun",
                        defaultValue: "cmux use: --command cannot be used with --no-run"
                    ))
                }
                commandMode = .override(command)
                index += 2
            case "--no-run":
                if case .override = commandMode {
                    throw CLIError(message: String(
                        localized: "cli.use.error.commandCannotCombineNoRun",
                        defaultValue: "cmux use: --command cannot be used with --no-run"
                    ))
                }
                commandMode = .none
                index += 1
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: String(
                        localized: "cli.use.error.unknownFlag",
                        defaultValue: "cmux use: unknown flag '\(arg)'. Known flags: --command <cmd>, --no-run"
                    ))
                }
                if repositoryArg == nil {
                    repositoryArg = arg
                    index += 1
                } else {
                    throw CLIError(message: String(
                        localized: "cli.use.error.unexpectedArgument",
                        defaultValue: "cmux use: unexpected argument '\(arg)'"
                    ))
                }
            }
        }

        guard let repositoryArg,
              !repositoryArg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: String(
                localized: "cli.use.error.usageWithFlags",
                defaultValue: "Usage: cmux use <owner/repo|github-url> [--command <cmd>] [--no-run]"
            ))
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
        let launchScript = try detectedCommand.map { try writeUseLaunchCommandScript($0.command) }
        var shouldRemoveLaunchScriptOnFailure = launchScript != nil
        defer {
            if shouldRemoveLaunchScriptOnFailure, let launchScript {
                try? FileManager.default.removeItem(at: launchScript.url)
            }
        }

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
                "description": String(
                    localized: "cli.use.workspaceDescription",
                    defaultValue: "cmux extension: \(repository.fullName)"
                ),
                "initial_env": initialEnv,
            ]
            if let windowOverride,
               let normalizedWindow = try normalizeWindowHandle(windowOverride, client: client) {
                params["window_id"] = normalizedWindow
            }
            if let launchScript {
                params["initial_command"] = launchScript.initialCommand
            }

            let response = try client.sendV2(method: "workspace.create", params: params)
            let formattedResponse = formatIDs(response, mode: idFormat) as? [String: Any] ?? response
            let workspaceHandle = (formattedResponse["workspace_ref"] as? String)
                ?? (formattedResponse["workspace_id"] as? String)
                ?? (response["workspace_ref"] as? String)
                ?? (response["workspace_id"] as? String)
            guard let workspaceHandle, !workspaceHandle.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.use.error.workspaceCreateMissingID",
                    defaultValue: "workspace.create did not return workspace_id or workspace_ref"
                ))
            }
            shouldRemoveLaunchScriptOnFailure = false

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

            print(String(localized: "cli.use.output.ok", defaultValue: "OK \(workspaceHandle)"))
            print(String(localized: "cli.use.output.repository", defaultValue: "Repository: \(repository.fullName)"))
            print(String(localized: "cli.use.output.mode", defaultValue: "Mode: \(install.mode)"))
            print(String(localized: "cli.use.output.extension", defaultValue: "Extension: \(manifest.id) \(manifest.version)"))
            print(String(localized: "cli.use.output.manifest", defaultValue: "Manifest: \(manifest.sourceFile)"))
            if let generatedManifestURL {
                print(String(
                    localized: "cli.use.output.generatedManifest",
                    defaultValue: "Generated manifest: \(generatedManifestURL.path)"
                ))
            }
            print(String(localized: "cli.use.output.path", defaultValue: "Path: \(install.url.path)"))
            print(String(localized: "cli.use.output.source", defaultValue: "Source: \(sourceCheckout.url.path)"))
            print(String(localized: "cli.use.output.install", defaultValue: "Install: \(install.action)"))
            if let detectedCommand {
                print(String(localized: "cli.use.output.command", defaultValue: "Command: \(detectedCommand.command)"))
                print(String(localized: "cli.use.output.detected", defaultValue: "Detected: \(detectedCommand.source)"))
            } else {
                print(String(
                    localized: "cli.use.output.noCommandDetected",
                    defaultValue: "Command: none detected; workspace opened at the checkout"
                ))
            }
        }
    }
}
