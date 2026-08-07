import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    private func hermesAgentApprovalPayload(
        def: AgentHookDef,
        input: ClaudeHookParsedInput
    ) -> (event: String, extra: [String: Any])? {
        guard def.name == "hermes-agent",
              let object = input.rawObject ?? input.object,
              let event = firstString(
                  in: object,
                  keys: ["hook_event_name", "hookEventName", "event", "event_name"]
              )?.lowercased(),
              event == "pre_approval_request" || event == "post_approval_response" else {
            return nil
        }
        return (event, (object["extra"] as? [String: Any]) ?? [:])
    }

    func hermesAgentApprovalSessionId(
        def: AgentHookDef,
        input: ClaudeHookParsedInput
    ) -> String? {
        guard let payload = hermesAgentApprovalPayload(def: def, input: input) else { return nil }
        return normalizedHookValue(firstString(in: payload.extra, keys: ["session_key", "sessionKey"]))
    }

    func isHermesAgentAutomaticApprovalObservation(
        def: AgentHookDef,
        input: ClaudeHookParsedInput
    ) -> Bool {
        guard let payload = hermesAgentApprovalPayload(def: def, input: input) else { return false }
        return firstString(in: payload.extra, keys: ["surface"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "smart"
    }

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

        let configDirectoryFileError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryIsFile",
                defaultValue: "cmux could not create the hooks directory: a file exists at %@. Remove or rename the conflicting file, then run `cmux hooks setup` again."
            ),
            configDir
        )
        let configDirectoryCreateError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryCreateFailed",
                defaultValue: "cmux could not create the hooks directory at %@. Check the parent directory permissions and try again."
            ),
            configDir
        )
        var isConfigDirectory: ObjCBool = false
        if fm.fileExists(atPath: configDir, isDirectory: &isConfigDirectory) {
            guard isConfigDirectory.boolValue else {
                throw CLIError(message: configDirectoryFileError)
            }
        } else {
            do {
                try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            } catch {
                throw CLIError(message: configDirectoryCreateError)
            }
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
