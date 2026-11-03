import Darwin
import Foundation

/// Kiro CLI v3 global hook definitions, installation, and ownership-preserving removal.
extension CMUXCLI {
    // MARK: - Kiro CLI V3 global hooks

    /// One lifecycle hook in the Kiro CLI V3 global hook file
    /// (https://kiro.dev/docs/hooks/).
    struct KiroGlobalHookEvent: Equatable {
        let name: String
        let trigger: String
        let cmuxSubcommand: String
        /// Agent-message delivery, whose stdout Kiro must see. Every other
        /// entry discards its output.
        var deliversMessages = false
    }

    /// Lifecycle and agent-message events cmux installs for every Kiro CLI V3
    /// agent. The Feed permission bridge (pre/post tool use) stays in the
    /// `cmux` agent config: a global PreToolUse hook would gate tools for
    /// every agent.
    static let kiroGlobalHookEvents: [KiroGlobalHookEvent] = [
        .init(name: "cmux-session-start", trigger: "SessionStart", cmuxSubcommand: "session-start"),
        .init(name: "cmux-prompt-submit", trigger: "UserPromptSubmit", cmuxSubcommand: "prompt-submit"),
        .init(name: "cmux-stop", trigger: "Stop", cmuxSubcommand: "stop"),
        .init(name: "cmux-session-end", trigger: "SessionEnd", cmuxSubcommand: "session-end"),
        .init(
            name: "cmux-inbox-drain", trigger: "UserPromptSubmit", cmuxSubcommand: "inbox-drain",
            deliversMessages: true
        ),
        .init(name: "cmux-inbox-stop", trigger: "Stop", cmuxSubcommand: "inbox-stop", deliversMessages: true),
    ]

    static let kiroGlobalHooksFileName = "cmux.json"
    static let kiroGlobalHookIdentityMarker = "cmux-kiro-global-hook"

    /// Kiro CLI V3 reads global hooks from the `hooks` directory beside
    /// `agents`: `~/.kiro/hooks`, or `$KIRO_HOME/hooks` when `KIRO_HOME` is set.
    static func kiroGlobalHooksDirectory(for def: AgentHookDef) -> String {
        URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("hooks", isDirectory: true)
            .path
    }

    static func kiroGlobalHooksFilePath(for def: AgentHookDef) -> String {
        URL(fileURLWithPath: kiroGlobalHooksDirectory(for: def), isDirectory: true)
            .appendingPathComponent(kiroGlobalHooksFileName, isDirectory: false)
            .path
    }

    /// Kiro CLI V3 adds a successful SessionStart/UserPromptSubmit hook's
    /// stdout to the model context, reads a Stop hook's stdout as a possible
    /// "keep working" decision, and forwards any other exit code's output to
    /// the agent. The global hook runs for every agent, so lifecycle entries
    /// discard all output and every entry exits 0. Message entries print only
    /// when a message is waiting for this surface.
    static func kiroGlobalHookCommandString(for def: AgentHookDef, event: KiroGlobalHookEvent) -> String {
        if event.deliversMessages {
            return [
                ": \(kiroGlobalHookIdentityMarker)",
                "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
                "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
                // An older cmux without Kiro message hooks answers `{}`, which
                // Kiro would add to the model context.
                "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then out=\"$(CMUX_KIRO_GLOBAL_HOOK=1 \"$cmux_cli\" hooks \(def.name) \(event.cmuxSubcommand) 2>/dev/null)\"; [ -n \"$out\" ] && [ \"$out\" != \"{}\" ] && printf '%s\\n' \"$out\"; else cat >/dev/null; fi",
                "exit 0",
            ].joined(separator: "; ")
        }
        let dispatch = queuedAgentHookShellCommand(
            agent: def.name,
            subcommand: event.cmuxSubcommand,
            disableEnvironmentVariable: def.disableEnvVar,
            identityMarker: kiroGlobalHookIdentityMarker
        )
        return "{ export CMUX_KIRO_GLOBAL_HOOK=1; \(dispatch); } >/dev/null 2>&1; exit 0"
    }

    static func kiroGlobalHookEntries(for def: AgentHookDef) -> [[String: Any]] {
        kiroGlobalHookEvents.map { event in
            [
                "name": event.name,
                "trigger": event.trigger,
                "action": [
                    "type": "command",
                    "command": kiroGlobalHookCommandString(for: def, event: event),
                ] as [String: Any],
                "timeout": agentHookDeclaredTimeoutSeconds,
                "enabled": true,
            ]
        }
    }

    /// Left in the global file when uninstall keeps other hooks or keys, so a
    /// later install still recognizes the file as cmux's. Disabled and a no-op.
    static let kiroGlobalOwnershipEntryName = "cmux-ownership"
    static var kiroGlobalOwnershipEntry: [String: Any] {
        [
            "name": kiroGlobalOwnershipEntryName,
            "trigger": "SessionEnd",
            "action": [
                "type": "command",
                "command": ": \(kiroGlobalHookIdentityMarker); exit 0",
            ] as [String: Any],
            "timeout": agentHookDeclaredTimeoutSeconds,
            "enabled": false,
        ]
    }

    static func isCmuxOwnedKiroGlobalHookEntry(_ entry: [String: Any]) -> Bool {
        guard let name = entry["name"] as? String,
              let trigger = entry["trigger"] as? String,
              let action = entry["action"] as? [String: Any],
              action["type"] as? String == "command",
              let command = action["command"] as? String,
              command.contains(": \(kiroGlobalHookIdentityMarker);") else { return false }
        // Keep the reserved name/trigger/marker tuple stable across command
        // upgrades. A marker quoted inside an unrelated user hook is not ours.
        if name == kiroGlobalOwnershipEntryName {
            return trigger == "SessionEnd" && entry["enabled"] as? Bool == false
                && command == ": \(kiroGlobalHookIdentityMarker); exit 0"
        }
        return kiroGlobalHookEvents.contains { $0.name == name && $0.trigger == trigger }
    }

    static var kiroGlobalRequiresKiroMessage: String {
        String(
            localized: "cli.hooks.error.globalRequiresKiro",
            defaultValue: "--global is only supported for Kiro. Usage: cmux hooks setup kiro --global", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
        )
    }

    static var kiroBothInstallsNote: String {
        String(
            localized: "cli.hooks.kiro.global.bothInstalledNote",
            defaultValue: "Note: the cmux agent config and the Kiro CLI V3 global hooks are both installed. Kiro CLI V3 merges hooks from every scope, so a `--agent cmux` session on V3 can report each session start, prompt and stop twice. On V3, start Kiro without `--agent cmux`, or remove the global file with `cmux hooks uninstall kiro --global`.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
        )
    }

    static var kiroGlobalHelpSummary: String {
        String(
            localized: "cli.hooks.kiro.global.postInstallNote",
            defaultValue: "These global hooks are for Kiro CLI V3 only (`kiro-cli --v3`) and run for every agent. Kiro CLI 2.x and earlier ignore this file; use the default install (`cmux hooks setup kiro`) and `--agent cmux` there. Feed permission approvals still need `--agent cmux`.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
        )
    }

    /// Whether the `cmux` Kiro agent config carries cmux's lifecycle hooks.
    /// Kiro CLI V3 merges agent-scope and global hooks, so with both present
    /// a V3 `--agent cmux` session can report each lifecycle event twice.
    private static func kiroAgentConfigHasCmuxLifecycleHooks(_ def: AgentHookDef) -> Bool {
        let filePath = URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent(def.configFile, isDirectory: false)
            .path
        guard let data = FileManager.default.contents(atPath: filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        return def.events.contains { event in
            (hooks[event.agentEvent] as? [[String: Any]])?.contains {
                isCmuxOwnedHookCommand($0["command"] as? String ?? "", for: def)
            } == true
        }
    }

    static func kiroGlobalHooksInstalled(_ def: AgentHookDef) -> Bool {
        guard let data = FileManager.default.contents(atPath: kiroGlobalHooksFilePath(for: def)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["hooks"] as? [[String: Any]] else {
            return false
        }
        return entries.contains(where: isCmuxOwnedKiroGlobalHookEntry)
    }

    /// `cmux hooks setup kiro --global`: writes cmux's lifecycle hooks to the
    /// Kiro CLI V3 global hooks file so they run for every agent. Entries cmux
    /// did not write are kept; a same-named file cmux did not write is refused.
    func installKiroGlobalHooks(_ def: AgentHookDef) throws {
        try Self.validateHookInstallDispatch(for: def)
        let fm = FileManager.default
        let hooksDir = Self.kiroGlobalHooksDirectory(for: def)
        let filePath = Self.kiroGlobalHooksFilePath(for: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: hooksDir, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.error.configDirectoryIsFile",
                    defaultValue: "cmux could not create the hooks directory: a file exists at %@. Remove or rename the conflicting file, then run `cmux hooks setup` again.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
                ),
                hooksDir
            ))
        }

        var document: [String: Any] = [:]
        var foreignEntries: [[String: Any]] = []
        let oldData = try kiroGlobalHooksData(atPath: filePath)
        if let oldData {
            guard let json = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any] else {
                throw CLIError(message: String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.invalidJSON", defaultValue: "%@ exists but is not valid JSON. Fix or remove it before installing hooks.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), filePath))
            }
            // Adopt only a file that already holds cmux's entries, so a
            // same-named file someone else wrote is never rewritten.
            guard let entries = json["hooks"] as? [[String: Any]],
                  entries.contains(where: Self.isCmuxOwnedKiroGlobalHookEntry) else {
                throw CLIError(message: String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.notOwned", defaultValue: "%@ exists and was not written by cmux. Rename it, then run `cmux hooks setup kiro --global` again.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), filePath))
            }
            foreignEntries = entries.filter { !Self.isCmuxOwnedKiroGlobalHookEntry($0) }
            document = json
        }
        document["version"] = "v1"
        document["hooks"] = Self.kiroGlobalHookEntries(for: def) + foreignEntries

        let newData = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let newString = String(data: newData, encoding: .utf8) ?? "{}"
        let oldString: String = {
            if let oldData,
               let json = try? JSONSerialization.jsonObject(with: oldData),
               let pretty = try? JSONSerialization.data(
                   withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
               ),
               let string = String(data: pretty, encoding: .utf8) {
                return string
            }
            return ""
        }()

        if oldString == newString {
            print(String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.alreadyUpToDate", defaultValue: "%@ global hooks already up to date at %@", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), def.displayName, filePath))
        } else {
            if !skipConfirm {
                print(
                    String(
                        localized: "cli.hooks.kiro.global.confirmSummary",
                        defaultValue: "cmux will update Kiro's global hooks and preserve hooks it did not install.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
                    )
                )
                print(String(localized: "cli.hooks.kiro.global.confirmProceed", defaultValue: "\nProceed? [y/N] ", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else {
                    print(String(localized: "cli.hooks.kiro.global.aborted", defaultValue: "Aborted.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main))
                    return
                }
            }
            try fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
            guard try mutateKiroGlobalHooks(atPath: filePath, expected: oldData, replacement: newData) else {
                return
            }
            print(String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.installed", defaultValue: "%@ global hooks installed at %@", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), def.displayName, filePath))
        }

        print(String(
            localized: "cli.hooks.kiro.global.postInstallNote",
            defaultValue: "These global hooks are for Kiro CLI V3 only (`kiro-cli --v3`) and run for every agent. Kiro CLI 2.x and earlier ignore this file; use the default install (`cmux hooks setup kiro`) and `--agent cmux` there. Feed permission approvals still need `--agent cmux`.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
        ))
        if Self.kiroAgentConfigHasCmuxLifecycleHooks(def) {
            print(Self.kiroBothInstallsNote)
        }
    }

    /// `cmux hooks uninstall kiro --global`: removes cmux's entries from the
    /// global hooks file, deleting the file only when nothing else is left.
    func uninstallKiroGlobalHooks(_ def: AgentHookDef) throws {
        let filePath = Self.kiroGlobalHooksFilePath(for: def)
        guard let data = try kiroGlobalHooksData(atPath: filePath) else {
            print(String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.noneFound", defaultValue: "No %@ found at %@", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), Self.kiroGlobalHooksFileName, filePath))
            return
        }
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.uninstallInvalidJSON", defaultValue: "%@ is not valid JSON. cmux left it unchanged.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), filePath))
        }
        guard let entries = json["hooks"] as? [[String: Any]] else {
            print(String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.noCmuxHooks", defaultValue: "No cmux hooks found in %@; left it unchanged", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), filePath))
            return
        }
        let remaining = entries.filter { !Self.isCmuxOwnedKiroGlobalHookEntry($0) }
        guard entries.contains(where: Self.isCmuxOwnedKiroGlobalHookEntry) else {
            print(String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.noCmuxHooks", defaultValue: "No cmux hooks found in %@; left it unchanged", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), filePath))
            return
        }
        let otherKeys = Set(json.keys).subtracting(["version", "hooks"])
        if remaining.isEmpty, otherKeys.isEmpty {
            guard try mutateKiroGlobalHooks(atPath: filePath, expected: data, replacement: nil) else { return }
            print(String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.removedAndDeleted", defaultValue: "Removed cmux hooks and deleted %@", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), filePath))
            return
        }
        json["hooks"] = remaining + [Self.kiroGlobalOwnershipEntry]
        let newData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard try mutateKiroGlobalHooks(atPath: filePath, expected: data, replacement: newData) else { return }
        print(String.localizedStringWithFormat(String(localized: "cli.hooks.kiro.global.removed", defaultValue: "Removed cmux hooks from %@", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main), filePath))
    }

    /// Serializes cmux writers and rechecks the exact snapshot after taking the
    /// lock. The confirmation prompt never holds the lock; a competing edit
    /// requires a fresh ownership check and preview even with --yes.
    private func mutateKiroGlobalHooks(atPath path: String, expected: Data?, replacement: Data?) throws -> Bool {
        let descriptor = Darwin.open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(descriptor) }
        var result: Int32
        repeat { result = flock(descriptor, LOCK_EX) } while result != 0 && errno == EINTR
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = flock(descriptor, LOCK_UN) }
        let current = try kiroGlobalHooksData(atPath: path)
        guard current == expected else {
            throw CLIError(message: String(
                localized: "cli.hooks.kiro.global.changedDuringConfirmation",
                defaultValue: "The Kiro global hooks file changed while cmux was waiting. No changes were made; run the command again.", bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
            ))
        }
        if let replacement {
            try replacement.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            try FileManager.default.removeItem(atPath: path)
        }
        return true
    }

    private func kiroGlobalHooksData(atPath path: String) throws -> Data? {
        do { return try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // A missing target does not make a user-owned symlink absent.
            var metadata = stat()
            guard lstat(path, &metadata) != 0, errno == ENOENT else { throw error }
            return nil
        }
    }
}
