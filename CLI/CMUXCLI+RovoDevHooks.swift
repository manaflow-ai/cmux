import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func installRovoDevHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        var isDirectory = ObjCBool(false)
        if !fm.fileExists(atPath: configDir, isDirectory: &isDirectory) {
            try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        } else if !isDirectory.boolValue {
            throw CLIError(message: "\(configDir) exists but is not a directory. Move it aside before installing \(def.displayName) hooks.")
        }

        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = try rovoDevHooksContent(existing: oldString, def: def, shouldInstall: true)
        if oldString == newString {
            print("\(def.displayName) hooks already up to date at \(filePath)")
            return
        }

        if !skipConfirm {
            Self.printInstallPreview(
                path: filePath,
                oldContent: oldString,
                newContent: newString,
                fallbackContent: newString
            )
            print("\nProceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                return
            }
        }
        try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
        print("\(def.displayName) hooks installed at \(filePath)")
    }

    func uninstallRovoDevHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        guard fm.fileExists(atPath: filePath) else {
            print("No \(def.configFile) found at \(filePath)")
            return
        }
        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = try rovoDevHooksContent(existing: oldString, def: def, shouldInstall: false)
        guard oldString != newString else {
            print("Removed 0 cmux hook(s) from \(filePath)")
            return
        }
        try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
        print("Removed Rovo Dev cmux hooks from \(filePath)")
    }

    private func rovoDevHooksContent(
        existing: String,
        def: AgentHookDef,
        shouldInstall: Bool
    ) throws -> String {
        let events = def.events.map { event in
            RovoDevHookConfig.Event(
                name: event.agentEvent,
                command: hookCommand(for: def, event: event)
            )
        }
        if shouldInstall {
            return RovoDevHookConfig.installing(events: events, in: existing)
        }
        return RovoDevHookConfig.uninstalling(from: existing)
    }
}
