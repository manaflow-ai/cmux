import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    private static let kimiLifecycleHookTimeoutSeconds = 10
    private static let kimiFeedHookTimeoutSeconds = 120

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
        if !configPathExists {
            do {
                try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            } catch {
                throw CLIError(message: configDirectoryFileError)
            }
        }

        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = KimiCodeHookConfig.installing(events: kimiCodeHookEvents(def: def), in: oldString)
        if oldString == newString {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.kimi.alreadyUpToDate",
                    defaultValue: "%@ hooks already up to date at %@"
                ),
                def.displayName,
                filePath
            ))
            return
        }

        if !skipConfirm {
            Self.printInstallPreview(
                path: filePath,
                oldContent: oldString,
                newContent: newString,
                fallbackContent: newString
            )
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
        try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.installed",
                defaultValue: "%@ hooks installed at %@"
            ),
            def.displayName,
            filePath
        ))
    }

    func uninstallKimiHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        guard fm.fileExists(atPath: filePath) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.kimi.noneFound",
                    defaultValue: "No %@ found at %@"
                ),
                def.configFile,
                filePath
            ))
            return
        }
        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = KimiCodeHookConfig.uninstalling(from: oldString)
        guard oldString != newString else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.kimi.removedZero",
                    defaultValue: "Removed 0 cmux hook(s) from %@"
                ),
                filePath
            ))
            return
        }
        try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.removed",
                defaultValue: "Removed Kimi Code cmux hooks from %@"
            ),
            filePath
        ))
    }
}
