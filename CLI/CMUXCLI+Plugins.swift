import CmuxFoundation
import Darwin
import Foundation

/// `cmux plugin`: installs and enables app extension plugins
/// (`cmux-plugin.toml` with `kind = "extension"`). Everything except
/// `action invoke` works without a running app; the app is asked to reload
/// afterwards when it is reachable.
extension CMUXCLI {
    static func pluginUsage() -> String {
        String(
            localized: "cli.plugin.help",
            defaultValue: """
        Usage: cmux plugin <command> [args]

        Commands:
          install <git-url|owner/repo[/subdir]> [--subdir <path>] [--force] [--yes]
          link <dir> [--force]           Use a local plugin directory (for development)
          list [--json]
          enable <name> [--yes]          Review the plugin's commands and activate it
          disable <name>
          remove <name>
          reload                         Ask the running app to reread plugins
          action invoke <name>.<action>  Run a plugin action in the current workspace

        Plugins install to ~/.local/share/cmux/mux-plugins/extension and stay
        inactive until enabled. Changing a plugin's manifest disables it until it
        is enabled again. Plugins run with your user permissions; there is no sandbox.
        """
        )
    }

    /// Only `action invoke` needs the app; the rest manage files.
    func pluginCommandNeedsSocket(_ commandArgs: [String]) -> Bool {
        commandArgs.first?.lowercased() == "action"
    }

    func runPluginCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        var rest = Array(commandArgs.dropFirst())
        let force = takeFlag("--force", from: &rest)
        let assumeYes = takeFlag("--yes", from: &rest) || takeFlag("-y", from: &rest)
        let subdirectory = try takeOption("--subdir", from: &rest)
        let paths = CmuxPluginPaths()
        let installer = CmuxPluginInstaller(paths: paths)

        do {
            switch subcommand {
            case "list":
                printPluginList(CmuxPluginCatalog.load(paths: paths), jsonOutput: jsonOutput)
                return
            case "install":
                let source = try CmuxPluginSource.parse(try singleArgument(rest), subdirectory: subdirectory)
                try installPlugin(from: source, installer: installer, force: force, assumeYes: assumeYes)
            case "link":
                let directory = URL(fileURLWithPath: (try singleArgument(rest) as NSString).expandingTildeInPath)
                let linked = try installer.link(directory, replacing: force)
                let format = String(
                    localized: "cli.plugin.output.linked",
                    defaultValue: "Linked %1$@ to %2$@. It stays inactive until you run: cmux plugin enable %1$@"
                )
                print(String.localizedStringWithFormat(format, linked.name, directory.path))
            case "enable":
                let name = try singleArgument(rest)
                guard let plugin = CmuxPluginCatalog.load(paths: paths).plugin(named: name) else {
                    throw CmuxPluginManifestError("plugin '\(name)' is not installed; run cmux plugin list")
                }
                printPluginReview(plugin.manifest, directory: plugin.directory)
                let prompt = String(localized: "cli.plugin.prompt.enable", defaultValue: "Enable %@? [y/N] ")
                guard try confirmPlugin(String.localizedStringWithFormat(prompt, name), assumeYes: assumeYes) else { return }
                try CmuxPluginEnablementStore(fileURL: paths.enablementFile).enable(name, fingerprint: plugin.fingerprint)
                let format = String(localized: "cli.plugin.output.enabled", defaultValue: "Enabled %@.")
                print(String.localizedStringWithFormat(format, name))
            case "disable":
                let name = try singleArgument(rest)
                try CmuxPluginEnablementStore(fileURL: paths.enablementFile).disable(name)
                let format = String(localized: "cli.plugin.output.disabled", defaultValue: "Disabled %@.")
                print(String.localizedStringWithFormat(format, name))
            case "remove", "uninstall":
                let name = try singleArgument(rest)
                try installer.remove(name)
                let format = String(localized: "cli.plugin.output.removed", defaultValue: "Removed %@.")
                print(String.localizedStringWithFormat(format, name))
            case "reload":
                break
            case "help", "--help", "-h":
                print(Self.pluginUsage())
                return
            default:
                throw CLIError(message: Self.pluginUsage())
            }
        } catch let error as CmuxPluginManifestError {
            throw CLIError(message: error.message)
        }
        requestPluginReload(socketPath: socketPath, explicitPassword: explicitPassword, reportFailure: subcommand == "reload")
    }

    /// `cmux plugin action invoke <name>.<action>` runs through the app so
    /// the action gets the caller's workspace and surface as context.
    func runPluginActionCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let rest = Array(commandArgs.dropFirst())
        guard rest.first?.lowercased() == "invoke", rest.count == 2 else {
            throw CLIError(message: Self.pluginUsage())
        }
        let raw = rest[1]
        let id = raw.hasPrefix("plugin.") ? raw : "plugin.\(raw)"
        var params: [String: Any] = ["id": id]
        let environment = ProcessInfo.processInfo.environment
        if let workspaceID = environment["CMUX_WORKSPACE_ID"], !workspaceID.isEmpty {
            params["workspace_id"] = workspaceID
        }
        if let surfaceID = environment["CMUX_SURFACE_ID"], !surfaceID.isEmpty {
            params["surface_id"] = surfaceID
        }
        let response = try client.sendV2(method: "plugin.action.invoke", params: params)
        if jsonOutput {
            print(jsonString(response))
        }
    }

    // MARK: - Install

    private func installPlugin(
        from source: CmuxPluginSource,
        installer: CmuxPluginInstaller,
        force: Bool,
        assumeYes: Bool
    ) throws {
        let staging = try installer.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let checkout = staging.appendingPathComponent("checkout", isDirectory: true)
        try runPluginProcess(
            ["git", "clone", "--depth", "1", "--quiet", "--", source.cloneURL, checkout.path],
            in: staging
        )
        let pluginDirectory = source.subdirectory.map { checkout.appendingPathComponent($0, isDirectory: true) } ?? checkout
        let (manifest, _) = try installer.inspect(pluginDirectory)
        printPluginReview(manifest, directory: nil)
        let prompt = String(localized: "cli.plugin.prompt.install", defaultValue: "Install %@? [y/N] ")
        guard try confirmPlugin(String.localizedStringWithFormat(prompt, manifest.name), assumeYes: assumeYes) else { return }
        if let build = manifest.buildCommand {
            try runPluginProcess(Self.resolvedPluginArgv(build, directory: pluginDirectory), in: pluginDirectory)
        }
        let destination = try installer.commit(pluginDirectory, name: manifest.name, replacing: force)
        let format = String(
            localized: "cli.plugin.output.installed",
            defaultValue: "Installed %1$@ at %2$@. It stays inactive until you run: cmux plugin enable %1$@"
        )
        print(String.localizedStringWithFormat(format, manifest.name, destination.path))
    }

    private static func resolvedPluginArgv(_ argv: [String], directory: URL) -> [String] {
        guard let first = argv.first, first.contains("/"), !first.hasPrefix("/") else { return argv }
        return [directory.appendingPathComponent(first).standardizedFileURL.path] + argv.dropFirst()
    }

    /// Runs a child with inherited stdio. Bare names resolve through `PATH`.
    private func runPluginProcess(_ argv: [String], in directory: URL) throws {
        let process = Process()
        if argv[0].hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
        }
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CmuxPluginManifestError("\(argv.joined(separator: " ")) exited with status \(process.terminationStatus)")
        }
    }

    // MARK: - Review and confirmation

    /// Shows every command the plugin can run, so enabling is an informed choice.
    private func printPluginReview(_ manifest: CmuxPluginManifest, directory: URL?) {
        let header = String(
            localized: "cli.plugin.review.header",
            defaultValue: "%@ runs these commands with your user permissions (no sandbox):"
        )
        let title = [manifest.name, manifest.version].compactMap { $0 }.joined(separator: " ")
        print(String.localizedStringWithFormat(header, title))
        if let description = manifest.description {
            print("  \(description)")
        }
        if let directory {
            print("  \(directory.path)")
        }
        if let build = manifest.buildCommand {
            print(String(localized: "cli.plugin.review.build", defaultValue: "Build command, run once at install:"))
            print("  \(Self.displayArgv(build))")
        }
        if !manifest.actions.isEmpty {
            print(String(localized: "cli.plugin.review.actions", defaultValue: "Actions:"))
            for action in manifest.actions {
                var line = "  plugin.\(manifest.name).\(action.id)  \(action.title)"
                if let shortcut = action.shortcut {
                    line += "  [\(shortcut)]"
                }
                print(line)
                print("    \(Self.displayArgv(action.argv))")
            }
        }
        if !manifest.events.isEmpty {
            print(String(localized: "cli.plugin.review.events", defaultValue: "Event hooks:"))
            for hook in manifest.events {
                print("  \(hook.event)")
                print("    \(Self.displayArgv(hook.argv))")
            }
        }
    }

    private static func displayArgv(_ argv: [String]) -> String {
        argv.map { argument in
            argument.isEmpty || argument.contains(where: { " \t\"'$\\`".contains($0) })
                ? CmuxPluginInvocation.shellQuoted(argument)
                : argument
        }.joined(separator: " ")
    }

    private func confirmPlugin(_ prompt: String, assumeYes: Bool) throws -> Bool {
        if assumeYes { return true }
        guard isatty(STDIN_FILENO) == 1 else {
            throw CLIError(message: String(
                localized: "cli.plugin.error.confirmationRequired",
                defaultValue: "Confirmation required. Run this in a terminal, or pass --yes after reviewing the commands above."
            ))
        }
        print(prompt, terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard answer == "y" || answer == "yes" else {
            print(String(localized: "cli.plugin.output.cancelled", defaultValue: "Cancelled."))
            return false
        }
        return true
    }

    // MARK: - Output and helpers

    private func printPluginList(_ catalog: CmuxPluginCatalog, jsonOutput: Bool) {
        if jsonOutput {
            let plugins: [[String: Any]] = catalog.plugins.map { plugin in
                [
                    "name": plugin.name,
                    "version": plugin.manifest.version.map { $0 as Any } ?? NSNull(),
                    "status": plugin.status.rawValue,
                    "linked": plugin.isLinked,
                    "directory": plugin.directory.path,
                    "actions": plugin.manifest.actions.map { "plugin.\(plugin.name).\($0.id)" },
                    "events": plugin.manifest.events.map(\.event),
                ]
            }
            let problems = catalog.problems.map { ["name": $0.name, "message": $0.message] }
            print(jsonString(["plugins": plugins, "problems": problems]))
            return
        }
        if catalog.plugins.isEmpty, catalog.problems.isEmpty {
            print(String(localized: "cli.plugin.output.none", defaultValue: "No plugins installed."))
            return
        }
        for plugin in catalog.plugins {
            let version = plugin.manifest.version.map { " \($0)" } ?? ""
            let linked = plugin.isLinked ? " -> \(plugin.directory.path)" : ""
            print("\(plugin.name)\(version) [\(plugin.status.rawValue)]\(linked)")
            for action in plugin.manifest.actions {
                print("  plugin.\(plugin.name).\(action.id)  \(action.title)")
            }
            for hook in plugin.manifest.events {
                print("  on \(hook.event)")
            }
        }
        for problem in catalog.problems {
            cliWriteStderr("\(problem.name): \(problem.message)\n")
        }
    }

    /// Asks a running app to reread plugins. The files are already updated,
    /// so an unreachable app just picks them up at its next launch.
    private func requestPluginReload(socketPath: String, explicitPassword: String?, reportFailure: Bool) {
        do {
            let client = try connectClient(socketPath: socketPath, explicitPassword: explicitPassword, launchIfNeeded: false)
            defer { client.close() }
            _ = try client.sendV2(method: "plugin.reload")
        } catch {
            if reportFailure {
                cliWriteStderr("\(error)\n")
            }
        }
    }

    private func takeFlag(_ flag: String, from args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        args.remove(at: index)
        return true
    }

    private func takeOption(_ option: String, from args: inout [String]) throws -> String? {
        guard let index = args.firstIndex(of: option) else { return nil }
        guard index + 1 < args.count else { throw CLIError(message: Self.pluginUsage()) }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    private func singleArgument(_ args: [String]) throws -> String {
        guard args.count == 1, let value = args.first, !value.hasPrefix("-") else {
            throw CLIError(message: Self.pluginUsage())
        }
        return value
    }
}
