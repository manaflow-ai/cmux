import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    private static let kimiLifecycleHookTimeoutSeconds = 10
    private static let kimiFeedHookTimeoutSeconds = 120
    private static let legacyKimiConfigDirectory = ".kimi-code"
    private static let legacyKimiConfigDirectoryOverride = "KIMI_CODE_HOME"

    func kimiCodeHookEvents(def: AgentHookDef) -> [KimiCodeHookConfig.Event] {
        var events = def.events.map { event in
            KimiCodeHookConfig.Event(
                name: event.agentEvent,
                command: hookCommand(for: def, event: event),
                timeout: Self.kimiLifecycleHookTimeoutSeconds
            )
        }
        events.append(contentsOf: def.feedHookEvents.map { agentEvent in
            KimiCodeHookConfig.Event(
                name: agentEvent,
                command: feedHookCommand(for: def, agentEvent: agentEvent),
                timeout: Self.kimiFeedHookTimeoutSeconds
            )
        })
        return events
    }

    func installKimiHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let activeConfigURL = URL(fileURLWithPath: filePath, isDirectory: false)
        let legacyConfigURL = Self.legacyKimiConfigURL(fileName: def.configFile)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        let configDirectoryFileError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryIsFile",
                defaultValue: "cmux could not create the hooks directory: a file exists at %@; remove or rename the conflicting file and re-run `cmux hooks setup`"
            ),
            configDir
        )
        var isConfigDirectory = ObjCBool(false)
        let configPathExists = fm.fileExists(atPath: configDir, isDirectory: &isConfigDirectory)
        if configPathExists, !isConfigDirectory.boolValue {
            throw CLIError(message: configDirectoryFileError)
        }

        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = KimiCodeHookConfig.installing(events: kimiCodeHookEvents(def: def), in: oldString)
        let activeEdit: (url: URL, oldContent: String, newContent: String)? = oldString == newString
            ? nil
            : (url: activeConfigURL, oldContent: oldString, newContent: newString)
        if activeEdit == nil {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.kimi.alreadyUpToDate",
                    defaultValue: "%@ hooks already up to date at %@"
                ),
                def.displayName,
                filePath
            ))
        }

        var legacyEdit: (url: URL, oldContent: String, newContent: String)?
        var legacyCleanupFailed = false
        if Self.canonicalKimiConfigURL(activeConfigURL) != Self.canonicalKimiConfigURL(legacyConfigURL) {
            do {
                let legacyOldString = try readAgentHookConfig(
                    filePath: legacyConfigURL.path,
                    displayName: def.displayName
                )
                let legacyNewString = KimiCodeHookConfig.uninstalling(from: legacyOldString)
                if legacyOldString != legacyNewString {
                    legacyEdit = (
                        url: legacyConfigURL,
                        oldContent: legacyOldString,
                        newContent: legacyNewString
                    )
                }
            } catch {
                legacyCleanupFailed = true
            }
        }

        let edits = [activeEdit, legacyEdit].compactMap { $0 }
        if !skipConfirm, !edits.isEmpty {
            for edit in edits {
                Self.printInstallPreview(
                    path: edit.url.path,
                    oldContent: edit.oldContent,
                    newContent: edit.newContent,
                    fallbackContent: edit.newContent
                )
            }
            print(String(
                localized: "cli.hooks.kimi.confirmProceed",
                defaultValue: "\nProceed? [y/N] "
            ), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(
                    localized: "cli.hooks.kimi.aborted",
                    defaultValue: "Aborted."
                ))
                return
            }
        }

        if let activeEdit {
            if !configPathExists {
                do {
                    try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
                } catch {
                    throw CLIError(message: configDirectoryFileError)
                }
            }
            try activeEdit.newContent.write(to: activeEdit.url, atomically: true, encoding: .utf8)
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.kimi.installed",
                    defaultValue: "%@ hooks installed at %@"
                ),
                def.displayName,
                filePath
            ))
        }

        if let legacyEdit {
            do {
                try legacyEdit.newContent.write(to: legacyEdit.url, atomically: true, encoding: .utf8)
                print(String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.kimi.removed",
                        defaultValue: "Removed Kimi Code cmux hooks from %@"
                    ),
                    legacyEdit.url.path
                ))
            } catch {
                legacyCleanupFailed = true
            }
        }
        if legacyCleanupFailed {
            reportKimiLegacyCleanupWarning(
                activeConfigURL: activeConfigURL,
                legacyConfigURL: legacyConfigURL
            )
        }
    }

    func uninstallKimiHooks(_ def: AgentHookDef) throws {
        let configDir = def.resolvedConfigDir()
        let activeConfigURL = URL(fileURLWithPath: configDir, isDirectory: true)
            .appendingPathComponent(def.configFile, isDirectory: false)
        let legacyConfigURL = Self.legacyKimiConfigURL(fileName: def.configFile)
        let configURLs = [
            (url: activeConfigURL, isLegacy: false),
            (url: legacyConfigURL, isLegacy: true),
        ].reduce(into: [(url: URL, isLegacy: Bool)]()) { configs, config in
            let canonicalURL = Self.canonicalKimiConfigURL(config.url)
            guard !configs.contains(where: { Self.canonicalKimiConfigURL($0.url) == canonicalURL }) else { return }
            configs.append(config)
        }

        var foundConfig = false
        for config in configURLs where FileManager.default.fileExists(atPath: config.url.path) {
            foundConfig = true
            do {
                _ = try removeKimiHooks(at: config.url, def: def, reportNoChange: true)
            } catch {
                guard config.isLegacy else { throw error }
                reportKimiLegacyUninstallWarning(legacyConfigURL: config.url)
            }
        }
        guard !foundConfig else { return }

        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.noneFound",
                defaultValue: "No %@ found at %@"
            ),
            def.configFile,
            activeConfigURL.path
        ))
    }

    private func removeKimiHooks(
        at configURL: URL,
        def: AgentHookDef,
        reportNoChange: Bool
    ) throws -> Bool {
        let oldString = try readAgentHookConfig(filePath: configURL.path, displayName: def.displayName)
        let newString = KimiCodeHookConfig.uninstalling(from: oldString)
        guard oldString != newString else {
            if reportNoChange {
                print(String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.kimi.removedZero",
                        defaultValue: "Removed 0 cmux hook(s) from %@"
                    ),
                    configURL.path
                ))
            }
            return false
        }
        try newString.write(to: configURL, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.removed",
                defaultValue: "Removed Kimi Code cmux hooks from %@"
            ),
            configURL.path
        ))
        return true
    }

    private func reportKimiLegacyCleanupWarning(
        activeConfigURL: URL,
        legacyConfigURL: URL
    ) {
        let warning = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.legacyCleanupWarning",
                defaultValue: "Warning: cmux hooks are active at %@, but cmux could not remove its legacy hook block from %@. Check that path and re-run `cmux hooks setup kimi` to finish cleanup."
            ),
            activeConfigURL.path,
            legacyConfigURL.path
        )
        cliWriteStderr(warning + "\n")
    }

    private func reportKimiLegacyUninstallWarning(legacyConfigURL: URL) {
        let warning = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.legacyUninstallWarning",
                defaultValue: "Warning: cmux could not remove its legacy hook block from %@. Check that path and re-run `cmux hooks uninstall kimi` to finish cleanup."
            ),
            legacyConfigURL.path
        )
        cliWriteStderr(warning + "\n")
    }

    private static func legacyKimiConfigURL(fileName: String) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? NSHomeDirectory()
        let legacyDirectory = environment[legacyKimiConfigDirectoryOverride].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : NSString(string: trimmed).expandingTildeInPath
        }.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(legacyKimiConfigDirectory, isDirectory: true)
        return legacyDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func canonicalKimiConfigURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
