import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    private static let vibeLifecycleHookTimeoutSeconds: Double = 60
    private static let vibeFeedHookTimeoutSeconds: Double = 120

    func vibeHookEvents(def: AgentHookDef) -> [VibeHookConfig.Event] {
        var events = def.events.map { event in
            VibeHookConfig.Event(
                name: "cmux-\(event.cmuxSubcommand)",
                type: event.agentEvent,
                command: hookCommand(for: def, event: event),
                timeout: Self.vibeLifecycleHookTimeoutSeconds
            )
        }
        events.append(contentsOf: def.feedHookEvents.map { agentEvent in
            VibeHookConfig.Event(
                name: "cmux-feed-\(agentEvent)",
                type: agentEvent,
                command: feedHookCommand(for: def, agentEvent: agentEvent),
                timeout: Self.vibeFeedHookTimeoutSeconds
            )
        })
        return events
    }

    func installVibeHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let events = vibeHookEvents(def: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        let configDirectoryFileError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryIsFile",
                defaultValue: "cmux could not create the hooks directory: a file exists at %@. Remove or rename the conflicting file, then run `cmux hooks setup` again."
            ),
            configDir
        )
        var isConfigDirectory = ObjCBool(false)
        let configPathExists = fm.fileExists(atPath: configDir, isDirectory: &isConfigDirectory)
        if configPathExists, !isConfigDirectory.boolValue {
            throw CLIError(message: configDirectoryFileError)
        }

        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = VibeHookConfig.installing(events: events, in: oldString)

        if oldString == newString {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.vibe.alreadyUpToDate",
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
                localized: "cli.hooks.vibe.confirmProceed",
                defaultValue: "\nProceed? [y/N] "
            ), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(
                    localized: "cli.hooks.vibe.aborted",
                    defaultValue: "Aborted."
                ))
                return
            }
        }

        if !configPathExists {
            do {
                try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            } catch {
                throw CLIError(message: configDirectoryFileError)
            }
        }
        try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.vibe.installed",
                defaultValue: "%@ hooks installed at %@"
            ),
            def.displayName,
            filePath
        ))
    }

    func uninstallVibeHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"

        guard fm.fileExists(atPath: filePath) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.vibe.noneFound",
                    defaultValue: "No %@ found at %@"
                ),
                def.configFile,
                filePath
            ))
            return
        }

        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = VibeHookConfig.uninstalling(from: oldString)

        guard oldString != newString else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.vibe.removedZero",
                    defaultValue: "Removed 0 cmux hook(s) from %@"
                ),
                filePath
            ))
            return
        }

        try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.vibe.removed",
                defaultValue: "Removed Mistral Vibe cmux hooks from %@"
            ),
            filePath
        ))
    }
}
