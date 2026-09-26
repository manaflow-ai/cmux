import Foundation
import CmuxFoundation
import CmuxSettings

extension CMUXCLI {
    func runConfigCommand(
        commandArgs: [String],
        socketPath: String?,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let wantsJSON = jsonOutput || parsedArgs.head.contains("--json")
        let args = parsedArgs.arguments
        let subcommand = args.first?.lowercased() ?? "help"

        if hasHelpRequest(beforeSeparator: parsedArgs.head) {
            print(configUsage())
            return
        }

        switch subcommand {
        case "help":
            print(configUsage())
        case "get":
            guard args.count == 2 else {
                throw CLIError(message: "Usage: cmux config get <setting.path|sidebar-font-size|surface-tab-bar-font-size>")
            }
            if let key = canonicalFontSizeKey(args[1]) {
                try runConfigGetFontSize(forKey: key, jsonOutput: wantsJSON)
            } else {
                try runConfigGetSetting(path: args[1], jsonOutput: wantsJSON)
            }
        case "set":
            guard args.count == 3 else {
                throw CLIError(message: "Usage: cmux config set <setting.path> <value>")
            }
            if let key = canonicalFontSizeKey(args[1]) {
                try runConfigSetFontSize(
                    forKey: key,
                    rawValue: args[2],
                    socketPath: socketPath,
                    explicitPassword: explicitPassword,
                    jsonOutput: wantsJSON
                )
            } else {
                try runConfigSettingChange(
                    .set(path: args[1], value: CmuxSettingValue(commandLineArgument: args[2])),
                    jsonOutput: wantsJSON
                )
            }
        case "unset":
            guard args.count == 2 else {
                throw CLIError(message: "Usage: cmux config unset <setting.path>")
            }
            try runConfigSettingChange(.unset(path: args[1]), jsonOutput: wantsJSON)
        case "toggle":
            guard args.count == 2 else {
                throw CLIError(message: "Usage: cmux config toggle <setting.path>")
            }
            try runConfigSettingChange(.toggle(path: args[1]), jsonOutput: wantsJSON)
        case "cycle":
            guard args.count >= 3 else {
                throw CLIError(message: "Usage: cmux config cycle <setting.path> <value> [value...]")
            }
            try runConfigSettingChange(
                .cycle(path: args[1], values: args.dropFirst(2).map { CmuxSettingValue(commandLineArgument: $0) }),
                jsonOutput: wantsJSON
            )
        case "preset":
            guard args.count == 2 else {
                throw CLIError(message: "Usage: cmux config preset <name>")
            }
            try runConfigSettingChange(.preset(name: args[1]), jsonOutput: wantsJSON)
        case CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey, CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey:
            if args.count == 1 {
                try runConfigGetFontSize(forKey: subcommand, jsonOutput: wantsJSON)
            } else if args.count == 2 {
                try runConfigSetFontSize(
                    forKey: subcommand,
                    rawValue: args[1],
                    socketPath: socketPath,
                    explicitPassword: explicitPassword,
                    jsonOutput: wantsJSON
                )
            } else {
                throw CLIError(message: "Usage: cmux config \(subcommand) [points]")
            }
        case "path", "paths":
            guard args.count == 1 else {
                throw CLIError(message: "Usage: cmux config path")
            }
            printSettingsPaths(jsonOutput: wantsJSON)
        case "docs", "documentation":
            guard args.count == 1 else {
                throw CLIError(message: "Usage: cmux config docs")
            }
            try runDocsCommand(commandArgs: ["settings"], jsonOutput: wantsJSON)
        case "doctor", "check", "validate":
            let doctorArgs = Array(args.dropFirst())
            let report = try runConfigDoctor(
                arguments: doctorArgs,
                jsonOutput: wantsJSON,
                commandName: subcommand
            )
            if report.errorCount > 0 {
                throw CLIError(
                    message: CmuxConfigValidationLocalization().format(
                        "config.validation.cli.errorCount",
                        defaultValue: "cmux config %@ found %lld error(s)",
                        subcommand,
                        Int64(report.errorCount)
                    )
                )
            }
        case "reload":
            guard args.count == 1 else {
                throw CLIError(message: "Usage: cmux config reload")
            }
            guard let socketPath else {
                throw CLIError(message: "cmux config reload requires a socket-backed cmux command path")
            }
            let client = try connectClient(
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                launchIfNeeded: false
            )
            defer { client.close() }
            let response = try client.send(command: "reload_config")
            if response.hasPrefix("ERROR:") {
                throw CLIError(message: response)
            }
            print(response)
        default:
            throw CLIError(message: "Unknown config subcommand '\(subcommand)'. Run 'cmux config --help'.")
        }
    }

    func configCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let subcommand = parsedArgs.arguments.first?.lowercased() ?? "help"
        if ["get", "unset", "toggle", "cycle", "preset"].contains(subcommand) {
            return true
        }
        // `set` only reloads the running app for the Ghostty font-size keys;
        // cmux.json settings are applied by the app's file watcher.
        if subcommand == "set" {
            let key = parsedArgs.arguments.count > 1 ? parsedArgs.arguments[1] : ""
            return canonicalFontSizeKey(key) == nil
        }
        if subcommand == CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey
            || subcommand == CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey {
            return parsedArgs.arguments.count == 1
        }
        return hasHelpRequest(beforeSeparator: parsedArgs.head) ||
            ["help", "path", "paths", "docs", "documentation", "doctor", "check", "validate"].contains(subcommand)
    }

    func configUsage() -> String {
        let validationHelp = CmuxConfigValidationLocalization().string(
            "config.validation.cli.help",
            defaultValue: "Validate JSONC syntax and cmux config semantics."
        )
        return """
        Usage: cmux config <doctor|check|validate|path|paths|docs|documentation|reload|get|set|unset|toggle|cycle|preset|sidebar-font-size|surface-tab-bar-font-size>

        Inspect and change cmux.json settings, print configuration references, update selected Ghostty config keys, or reload the running app.

        Subcommands:
          doctor|check|validate [--path <path>] [--scope <global|project>]
                                                   \(validationHelp)
          path|paths                              Print cmux.json paths, docs URL, and schema URL.
          docs|documentation                      Print the same output as `cmux docs settings`.
          reload                                  Reload Ghostty config + cmux.json and refresh terminals (alias for `cmux reload-config`).
          get <setting.path>                      Print a cmux.json setting: its configured value, or the default.
          set <setting.path> <value>              Write a setting to ~/.config/cmux/cmux.json. <value> is JSON (true, 1.4, "dark", [...]);
                                                  other text is stored as a string. Comments and other keys are kept.
          unset <setting.path>                    Remove a setting so its default applies.
          toggle <setting.path>                   Flip a true/false setting.
          cycle <setting.path> <value> [value...] Move a setting to the value after its current one, wrapping around.
          preset <name>                           Apply the settings stored at settingPresets.<name> in cmux.json.
          get <key>                               Print sidebar-font-size or surface-tab-bar-font-size.
          set <key> <points>                      Set sidebar-font-size (10-20 pt) or surface-tab-bar-font-size (8-24 pt), then reload if cmux is running.
          sidebar-font-size [points]              Get or set the left sidebar text size.
          surface-tab-bar-font-size [points]      Get or set the workspace tab bar text size.

        Setting changes are validated against the cmux.json schema before anything is written. A running
        cmux applies them automatically; no reload is needed.

        Config files:
          \(Self.primarySettingsDisplayPath)
          legacy config: \(Self.legacySettingsDisplayPath)
          legacy app support: \(Self.fallbackSettingsDisplayPath)

        Related (not cmux-owned, but cmux reads it for terminal behavior):
          \(Self.ghosttyConfigDisplayPath)

        Examples:
          cmux config get terminal.scrollSpeed
          cmux config set terminal.scrollSpeed 1.4
          cmux config toggle fileEditor.wordWrap
          cmux config cycle terminal.scrollSpeed 1.0 1.4 1.8
          cmux config preset sidebar.quiet
          cmux config doctor
          cmux config doctor --path .cmux/cmux.json
          cmux config set sidebar-font-size 14
          cmux config sidebar-font-size 12.5
          cmux config set surface-tab-bar-font-size 13
          cmux config surface-tab-bar-font-size 11
          cmux config reload
        """
    }

    func printSettingsPaths(jsonOutput: Bool) {
        let payload: [String: Any] = [
            "primary": Self.primarySettingsDisplayPath,
            "legacy": Self.legacySettingsDisplayPath,
            "fallback": Self.fallbackSettingsDisplayPath,
            "ghostty_config": [
                "path": Self.ghosttyConfigDisplayPath,
                "note": "Not cmux-owned, but cmux reads it. Use for terminal transparency (background-opacity), blur, font, theme, etc.",
            ],
            "docs_url": Self.settingsDocsURL,
            "schema_url": Self.settingsSchemaURL,
            "reload_command": "cmux reload-config",
            "reload_scope": "Reloads Ghostty config + cmux.json and refreshes terminals in place. No app restart needed.",
            "backup": "Back up any existing cmux.json file to a timestamped .bak copy before editing so the user can revert.",
        ]

        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print("Config files:")
        print("  primary:  \(Self.primarySettingsDisplayPath)")
        print("  legacy config: \(Self.legacySettingsDisplayPath)")
        print("  legacy app support: \(Self.fallbackSettingsDisplayPath)")
        print()
        print("Related (not cmux-owned, but cmux reads it for terminal behavior):")
        print("  \(Self.ghosttyConfigDisplayPath)")
        print()
        print("Docs:")
        print("  \(Self.settingsDocsURL)")
        print()
        print("Schema:")
        print("  \(Self.settingsSchemaURL)")
        print()
        print("Before editing cmux.json:")
        print("  Back up any existing cmux.json file to a timestamped .bak copy so the user can revert.")
        print()
        print("Reload after editing (covers BOTH cmux.json and Ghostty config; no app restart needed):")
        print("  cmux reload-config")
    }

    /// Applies a setting change to the global cmux.json through the same
    /// ``JSONConfigStore/apply(_:)`` path setting actions use.
    private func runConfigSettingChange(_ change: CmuxSettingChange, jsonOutput: Bool) throws {
        let store = JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
        let result: CmuxSettingChangeResult
        do {
            result = try runConfigSettingsBlocking { try await store.apply(change) }
        } catch {
            throw CLIError(message: error.localizedDescription)
        }
        let changed = result.receipts.filter { $0.before != $0.installed }

        if jsonOutput {
            let paths: [[String: Any]] = result.receipts.map { receipt in
                var entry: [String: Any] = [
                    "path": receipt.path,
                    "changed": receipt.before != receipt.installed,
                ]
                if let value = result.installedValue(at: receipt.path) {
                    entry["value"] = value.jsonObject
                }
                return entry
            }
            print(jsonString([
                "ok": true,
                "file": store.fileURL.path,
                "paths": paths,
            ]))
            return
        }

        if changed.isEmpty {
            print("OK unchanged")
        }
        for receipt in changed {
            if let value = result.installedValue(at: receipt.path) {
                print("OK \(receipt.path) = \(value.jsonText)")
            } else {
                print("OK \(receipt.path) unset")
            }
        }
        print("path: \(Self.tildePath(store.fileURL.path))")
    }

    private func runConfigGetSetting(path: String, jsonOutput: Bool) throws {
        let store = JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
        let reading: CmuxSettingReading
        do {
            reading = try store.reading(at: path)
        } catch {
            throw CLIError(message: error.localizedDescription)
        }

        if jsonOutput {
            var payload: [String: Any] = [
                "key": reading.path,
                "configured": reading.configured != nil,
                "path": store.fileURL.path,
            ]
            payload["value"] = reading.effective?.jsonObject ?? NSNull()
            if let defaultValue = reading.defaultValue {
                payload["default"] = defaultValue.jsonObject
            }
            print(jsonString(payload))
            return
        }

        print("\(reading.path) = \(reading.effective?.jsonText ?? "null")\(reading.configured == nil ? " (default)" : "")")
    }

    /// Bridges the actor-backed store to this synchronous command. The
    /// semaphore orders the result hand-off after the task's write.
    private func runConfigSettingsBlocking<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output: Result<T, any Error>!
        Task {
            do { output = .success(try await work()) }
            catch { output = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try output.get()
    }

    /// Normalizes a user-supplied key to a supported editable font-size key, or nil if unsupported.
    private func canonicalFontSizeKey(_ raw: String) -> String? {
        switch raw.lowercased() {
        case CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey:
            return CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey
        case CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey:
            return CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey
        default:
            return nil
        }
    }

    private func fontSizeConfig(
        forKey key: String
    ) -> (defaultValue: Double, clamp: (Double) -> Double, format: (Double) -> String, parse: (String) -> Double?)? {
        switch key {
        case CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey:
            return (
                CmuxGhosttyConfigSettingEditor.defaultSidebarFontSize,
                CmuxGhosttyConfigSettingEditor().clampedSidebarFontSize,
                CmuxGhosttyConfigSettingEditor().formattedSidebarFontSize,
                { CmuxGhosttyConfigSettingEditor().parsedSidebarFontSize(in: $0) }
            )
        case CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey:
            return (
                CmuxGhosttyConfigSettingEditor.defaultSurfaceTabBarFontSize,
                CmuxGhosttyConfigSettingEditor().clampedSurfaceTabBarFontSize,
                CmuxGhosttyConfigSettingEditor().formattedSurfaceTabBarFontSize,
                { CmuxGhosttyConfigSettingEditor().parsedSurfaceTabBarFontSize(in: $0) }
            )
        default:
            return nil
        }
    }

    private func runConfigGetFontSize(forKey key: String, jsonOutput: Bool) throws {
        guard let descriptor = fontSizeConfig(forKey: key) else {
            throw CLIError(message: "Unknown font size key '\(key)'")
        }
        let url = try cmuxGhosttyConfigURLForCLI()
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let configuredValue = descriptor.parse(contents)
        let effectiveValue = configuredValue ?? descriptor.defaultValue
        let formattedValue = descriptor.format(effectiveValue)

        if jsonOutput {
            var payload: [String: Any] = [
                "key": key,
                "value": effectiveValue,
                "formatted": formattedValue,
                "path": url.path,
                "configured": configuredValue != nil,
            ]
            if let configuredValue {
                payload["configured_value"] = configuredValue
            }
            print(jsonString(payload))
            return
        }

        print("\(key) = \(formattedValue)")
        print("path: \(Self.tildePath(url.path))")
    }

    private func runConfigSetFontSize(
        forKey key: String,
        rawValue: String,
        socketPath: String?,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        guard let descriptor = fontSizeConfig(forKey: key) else {
            throw CLIError(message: "Unknown font size key '\(key)'")
        }
        guard let requestedValue = Double(rawValue), requestedValue.isFinite else {
            throw CLIError(message: "\(key) requires a numeric point size")
        }

        let value = descriptor.clamp(requestedValue)
        let formattedValue = descriptor.format(value)
        let url = try cmuxGhosttyConfigURLForCLI()
        try CmuxGhosttyConfigSettingEditor().writeSetting(
            key: key,
            value: formattedValue,
            to: url
        )

        let reloadResult = reloadConfigAfterFontSizeSet(
            socketPath: socketPath,
            explicitPassword: explicitPassword
        )

        if jsonOutput {
            var payload: [String: Any] = [
                "ok": true,
                "key": key,
                "value": value,
                "formatted": formattedValue,
                "path": url.path,
                "reload": reloadResult.status,
                "clamped": value != requestedValue,
            ]
            if let message = reloadResult.message {
                payload["reload_message"] = message
            }
            print(jsonString(payload))
            return
        }

        switch reloadResult.status {
        case "reloaded":
            print("OK \(key) = \(formattedValue) (reloaded)")
        case "failed":
            print("OK \(key) = \(formattedValue) (saved; reload failed)")
            if let message = reloadResult.message {
                print("reload: \(message)")
            }
            print("Run `cmux config reload` after cmux is running to apply it.")
        default:
            print("OK \(key) = \(formattedValue) (saved)")
            print("Run `cmux config reload` to apply it.")
        }
        print("path: \(Self.tildePath(url.path))")
    }

    private func cmuxGhosttyConfigURLForCLI() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let appSupportDirectories = CmuxApplicationSupportDirectories(environment: environment, fileManager: fileManager)
            .userDirectories
        guard let firstAppSupportDirectory = appSupportDirectories.first else {
            throw CLIError(message: "Could not resolve the user Application Support directory")
        }
        let bundleIdentifier = normalizedConfigValue(environment["CMUX_BUNDLE_ID"])
            ?? CLISocketPathResolver.currentAppBundleIdentifier()
        // Prefer an existing config under any candidate root (the app loads config
        // across all Application Support locations, including CFFIXED_USER_HOME),
        // so `config get/set` touches the same file the app reads. Fall back to
        // creating one under the first candidate when none exists yet.
        for appSupportDirectory in appSupportDirectories {
            if let existing = CmuxGhosttyConfigPathResolver().loadConfigURLs(
                currentBundleIdentifier: bundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            ).first {
                return existing
            }
        }
        return CmuxGhosttyConfigPathResolver().activeOrEditableConfigURL(
            currentBundleIdentifier: bundleIdentifier,
            appSupportDirectory: firstAppSupportDirectory,
            fileManager: fileManager
        )
    }

    private func reloadConfigAfterFontSizeSet(
        socketPath: String?,
        explicitPassword: String?
    ) -> (status: String, message: String?) {
        guard let socketPath else {
            return ("skipped", nil)
        }
        do {
            let client = try connectClient(
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                launchIfNeeded: false
            )
            defer { client.close() }
            let response = try client.send(command: "reload_config")
            if response.hasPrefix("ERROR:") {
                return ("failed", response)
            }
            return ("reloaded", response)
        } catch {
            return ("failed", Self.configDoctorErrorMessage(error))
        }
    }

    private func normalizedConfigValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
