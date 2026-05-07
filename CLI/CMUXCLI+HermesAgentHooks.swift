import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    func hermesAgentShellCommand(_ script: String) -> String {
        "sh -c \(shellQuote(script))"
    }

    func hermesAgentEvents(def: AgentHookDef) -> [HermesAgentHookConfig.Event] {
        var events = def.events.map { event in
            HermesAgentHookConfig.Event(
                name: event.agentEvent,
                command: hermesAgentShellCommand(hookCommand(for: def, event: event)),
                timeout: 5
            )
        }
        events.append(contentsOf: def.feedHookEvents.map { agentEvent in
            HermesAgentHookConfig.Event(
                name: agentEvent,
                command: hermesAgentShellCommand(feedHookCommand(for: def, agentEvent: agentEvent)),
                timeout: 120
            )
        })
        return events
    }

    func installHermesAgentHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let allowlistPath = "\(configDir)/shell-hooks-allowlist.json"
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        guard fm.fileExists(atPath: configDir) else {
            print("\(configDir) does not exist. Install \(def.displayName) first.")
            return
        }

        let events = hermesAgentEvents(def: def)
        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = HermesAgentHookConfig.installing(events: events, in: oldString)

        if oldString != newString {
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
        } else {
            print("\(def.displayName) hooks already up to date at \(filePath)")
        }

        let oldAllowlist = fm.contents(atPath: allowlistPath)
        let newAllowlist = try HermesAgentHookAllowlist.installing(events: events, in: oldAllowlist)
        if oldAllowlist != newAllowlist {
            try newAllowlist.write(to: URL(fileURLWithPath: allowlistPath), options: .atomic)
            print("Approved \(def.displayName) cmux shell hooks in \(allowlistPath)")
        }
    }

    func uninstallHermesAgentHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let allowlistPath = "\(configDir)/shell-hooks-allowlist.json"
        let events = hermesAgentEvents(def: def)

        if fm.fileExists(atPath: filePath) {
            let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
            let newString = HermesAgentHookConfig.uninstalling(from: oldString)
            if oldString != newString {
                try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
                print("Removed Hermes Agent cmux hooks from \(filePath)")
            } else {
                print("Removed 0 cmux hook(s) from \(filePath)")
            }
        } else {
            print("No \(def.configFile) found at \(filePath)")
        }

        guard fm.fileExists(atPath: allowlistPath) else { return }
        let oldAllowlist = fm.contents(atPath: allowlistPath)
        let newAllowlist = try HermesAgentHookAllowlist.uninstalling(events: events, from: oldAllowlist)
        if oldAllowlist != newAllowlist {
            try newAllowlist.write(to: URL(fileURLWithPath: allowlistPath), options: .atomic)
            print("Removed Hermes Agent cmux shell hook approvals from \(allowlistPath)")
        }
    }
}
