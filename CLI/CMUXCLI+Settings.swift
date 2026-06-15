import Foundation

/// `cmux settings <list|get|set|unset|reset|describe|export|import>` and
/// `cmux settings shortcuts <list|get|set|unset|reset>` — read and write every
/// cmux setting and remap every keyboard shortcut from the command line.
///
/// This is the data half of `cmux settings`; the GUI half (`open` / `path` /
/// `docs` / `<target>`) lives in `CMUXCLI+DocsSettings.swift`, which routes the
/// data subcommands here. The CLI is a thin client: it sends a
/// `settings.control.*` request to the running app over the control socket and
/// renders the reply. All catalog knowledge (which keys exist, their types,
/// enum cases, validation, redaction, live-apply) lives app-side in the
/// catalog-driven engine, so the CLI never hardcodes a key list and stays
/// current automatically as settings change.
extension CMUXCLI {
    /// Data subcommands always handled by the catalog-driven engine (vs. the
    /// GUI-opening `open` / `path` / `docs` / `<target>` subcommands).
    static let settingsControlSubcommands: Set<String> = [
        "list", "get", "set", "unset", "describe", "export", "import",
    ]

    /// Shortcut sub-subcommands handled by the engine. Bare `settings shortcuts`
    /// keeps opening the GUI for backward compatibility.
    static let settingsControlShortcutSubcommands: Set<String> = [
        "list", "get", "set", "unset", "reset",
    ]

    /// Whether `cmux settings <subcommand> …` should be handled by the
    /// catalog-driven engine rather than the GUI-opening path.
    func settingsUsesControlEngine(subcommand: String, args: [String]) -> Bool {
        if Self.settingsControlSubcommands.contains(subcommand) { return true }
        // `reset` is overloaded: `reset <key>` / `reset --all` clear overrides
        // (engine); bare `reset` still opens the GUI reset section.
        if subcommand == "reset" {
            let rest = Array(args.dropFirst())
            return rest.contains("--all") || rest.contains { !$0.hasPrefix("--") }
        }
        // `shortcuts <list|get|set|unset|reset>` manage bindings; bare
        // `shortcuts` opens the GUI.
        if subcommand == "shortcuts", let next = args.dropFirst().first?.lowercased() {
            return Self.settingsControlShortcutSubcommands.contains(next)
        }
        return false
    }

    /// Connects to the running app and dispatches one engine-backed subcommand.
    func runSettingsControl(
        subcommand: String,
        args: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let rest = Array(args.dropFirst()) // args[0] is the subcommand itself

        switch subcommand {
        case "list":
            try settingsControlList(rest, client: client, jsonOutput: jsonOutput)
        case "get":
            try settingsControlGet(rest, client: client, jsonOutput: jsonOutput)
        case "set":
            try settingsControlSet(rest, client: client, jsonOutput: jsonOutput)
        case "unset":
            try settingsControlUnset(rest, client: client, jsonOutput: jsonOutput)
        case "reset":
            try settingsControlReset(rest, client: client, jsonOutput: jsonOutput)
        case "describe":
            try settingsControlDescribe(rest, client: client, jsonOutput: jsonOutput)
        case "export":
            try settingsControlExport(rest, client: client, jsonOutput: jsonOutput)
        case "import":
            try settingsControlImport(rest, client: client, jsonOutput: jsonOutput)
        case "shortcuts":
            try settingsControlShortcuts(rest, client: client, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: "settings: unknown subcommand '\(subcommand)'.")
        }
    }

    // MARK: - Settings subcommands

    private func settingsControlList(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let keysOnly = hasFlag(args, name: "--keys")
        let payload = try client.sendV2(method: "settings.control.list")
        let rows = (payload["settings"] as? [[String: Any]]) ?? []

        if keysOnly {
            for row in rows {
                if let id = row["id"] as? String { print(id) }
            }
            return
        }
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        for row in rows {
            print(Self.settingsRowLine(row))
        }
    }

    private func settingsControlGet(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let key = try Self.requirePositional(args, name: "key", usage: "cmux settings get <key> [--json]")
        let payload = try client.sendV2(method: "settings.control.get", params: ["key": key])
        if jsonOutput {
            print(jsonString(payload))
        } else if let value = payload["value"] {
            print(Self.renderSettingValue(value))
        }
    }

    private func settingsControlSet(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let positionals = Self.positionalArgs(args)
        guard positionals.count == 2 else {
            throw CLIError(message: "Usage: cmux settings set <key> <value>  (quote values that contain spaces)")
        }
        let payload = try client.sendV2(
            method: "settings.control.set",
            params: ["key": positionals[0], "value": positionals[1]]
        )
        if jsonOutput {
            print(jsonString(payload))
        } else if let value = payload["value"] {
            print("set \(positionals[0]) = \(Self.renderSettingValue(value))")
        }
    }

    private func settingsControlUnset(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let key = try Self.requirePositional(args, name: "key", usage: "cmux settings unset <key>")
        let payload = try client.sendV2(method: "settings.control.unset", params: ["key": key])
        if jsonOutput {
            print(jsonString(payload))
        } else if let value = payload["value"] {
            print("unset \(key) (now \(Self.renderSettingValue(value)))")
        }
    }

    private func settingsControlReset(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        if hasFlag(args, name: "--all") {
            if !hasFlag(args, name: "--yes") {
                throw CLIError(message: "cmux settings reset --all clears every override. Re-run with --yes to confirm.")
            }
            let payload = try client.sendV2(method: "settings.control.reset", params: ["all": true])
            if jsonOutput { print(jsonString(payload)) } else { print("reset all settings to defaults") }
            return
        }
        let key = try Self.requirePositional(
            Self.positionalArgs(args), name: "key",
            usage: "cmux settings reset <key>   |   cmux settings reset --all --yes"
        )
        let payload = try client.sendV2(method: "settings.control.reset", params: ["key": key])
        if jsonOutput {
            print(jsonString(payload))
        } else if let value = payload["value"] {
            print("reset \(key) (now \(Self.renderSettingValue(value)))")
        }
    }

    private func settingsControlDescribe(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let key = try Self.requirePositional(args, name: "key", usage: "cmux settings describe <key> [--json]")
        let payload = try client.sendV2(method: "settings.control.describe", params: ["key": key])
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        print("\(key)")
        if let type = payload["type"] as? String { print("  type:     \(type)") }
        if let allowed = payload["allowedValues"] as? [String] {
            print("  allowed:  \(allowed.joined(separator: ", "))")
        }
        if let value = payload["value"] { print("  value:    \(Self.renderSettingValue(value))") }
        if let def = payload["default"] { print("  default:  \(Self.renderSettingValue(def))") }
        if let backend = payload["backend"] as? String { print("  backend:  \(backend)") }
        if let section = payload["section"] as? String { print("  section:  \(section)") }
        if let overridden = payload["overridden"] as? Bool { print("  source:   \(overridden ? "set" : "default")") }
        if (payload["secret"] as? Bool) == true { print("  secret:   yes (value redacted)") }
    }

    private func settingsControlExport(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let payload = try client.sendV2(method: "settings.control.export")
        let document: [String: Any] = ["settings": payload["settings"] ?? [String: Any]()]
        let text = jsonString(document)
        if let outPath = optionValue(args, name: "--out") {
            try text.write(toFile: (outPath as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
            print("exported settings to \(outPath)")
        } else {
            print(text)
        }
    }

    private func settingsControlImport(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let path = try Self.requirePositional(Self.positionalArgs(args), name: "file", usage: "cmux settings import <file>")
        let expanded = (path as NSString).expandingTildeInPath
        let document = try String(contentsOfFile: expanded, encoding: .utf8)
        let payload = try client.sendV2(method: "settings.control.import", params: ["document": document])
        if jsonOutput {
            print(jsonString(payload))
        } else {
            let count = (payload["count"] as? Int) ?? (payload["count"] as? NSNumber)?.intValue ?? 0
            print("imported \(count) setting\(count == 1 ? "" : "s") from \(path)")
        }
    }

    // MARK: - Shortcuts subtree

    private func settingsControlShortcuts(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let sub = args.first?.lowercased() else {
            throw CLIError(message: Self.settingsShortcutsUsage)
        }
        let rest = Array(args.dropFirst())

        switch sub {
        case "list":
            let payload = try client.sendV2(method: "settings.control.shortcuts.list")
            if jsonOutput {
                print(jsonString(payload))
            } else {
                for row in (payload["shortcuts"] as? [[String: Any]]) ?? [] {
                    print(Self.shortcutRowLine(row))
                }
            }
        case "get":
            let action = try Self.requirePositional(rest, name: "action", usage: "cmux settings shortcuts get <action>")
            let payload = try client.sendV2(method: "settings.control.shortcuts.get", params: ["action": action])
            if jsonOutput { print(jsonString(payload)) } else { print((payload["binding"] as? String) ?? "none") }
        case "set":
            let positionals = Self.positionalArgs(rest)
            guard positionals.count == 2 else {
                throw CLIError(message: "Usage: cmux settings shortcuts set <action> <key-combo> [--force]  (e.g. \"cmd+t\")")
            }
            var params: [String: Any] = ["action": positionals[0], "value": positionals[1]]
            if hasFlag(rest, name: "--force") { params["force"] = true }
            let payload = try client.sendV2(method: "settings.control.shortcuts.set", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print("set \(positionals[0]) = \((payload["binding"] as? String) ?? positionals[1])")
            }
        case "unset":
            let action = try Self.requirePositional(rest, name: "action", usage: "cmux settings shortcuts unset <action>")
            let payload = try client.sendV2(method: "settings.control.shortcuts.unset", params: ["action": action])
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print("unset \(action) (now \((payload["binding"] as? String) ?? "default"))")
            }
        case "reset":
            let payload = try client.sendV2(method: "settings.control.shortcuts.reset")
            if jsonOutput { print(jsonString(payload)) } else { print("reset all shortcut overrides") }
        default:
            throw CLIError(message: "settings shortcuts: unknown subcommand '\(sub)'.\n\n\(Self.settingsShortcutsUsage)")
        }
    }

    // MARK: - Rendering helpers

    private static func settingsRowLine(_ row: [String: Any]) -> String {
        let id = (row["id"] as? String) ?? "?"
        let value = row["value"].map(renderSettingValue) ?? ""
        let backend = (row["backend"] as? String) ?? ""
        let source = (row["source"] as? String) ?? ((row["overridden"] as? Bool) == true ? "set" : "default")
        return "\(id)\t\(value)\t[\(backend), \(source)]"
    }

    private static func shortcutRowLine(_ row: [String: Any]) -> String {
        let action = (row["action"] as? String) ?? "?"
        let binding = (row["binding"] as? String) ?? "none"
        let def = (row["default"] as? String) ?? "none"
        let suffix = ((row["overridden"] as? Bool) == true) ? "  (default: \(def))" : ""
        return "\(action)\t\(binding)\(suffix)"
    }

    /// Renders a JSON value for human output: scalars bare, structured values as
    /// compact JSON. `Bool` is checked before the numeric cases because a JSON
    /// boolean bridges to `NSNumber`.
    static func renderSettingValue(_ value: Any) -> String {
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let int = value as? Int { return String(int) }
        if let double = value as? Double { return String(double) }
        if let string = value as? String { return string }
        if value is NSNull { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    // MARK: - Arg helpers

    private static func positionalArgs(_ args: [String]) -> [String] {
        args.filter { !$0.hasPrefix("--") }
    }

    private static func requirePositional(_ args: [String], name: String, usage: String) throws -> String {
        let positionals = positionalArgs(args)
        guard let first = positionals.first else {
            throw CLIError(message: "missing <\(name)>. Usage: \(usage)")
        }
        return first
    }

    /// Top-level `cmux settings` usage. Lives here (with the read/write
    /// subcommands it documents) rather than in `CMUXCLI+DocsSettings.swift`,
    /// which owns the GUI-open path; the `Self.*DisplayPath` constants resolve
    /// across the shared `CMUXCLI` extension.
    func settingsUsage() -> String {
        return """
        Usage: cmux settings <subcommand> [args]

        Read and write every cmux setting and keyboard shortcut, or open the GUI.

        Read/write subcommands (catalog-driven; require a running cmux app):
          list [--json] [--keys]    List every setting (id, value, default, backend).
          get <key> [--json]        Print one setting's value.
          set <key> <value>         Set a value (validated against the catalog).
          unset <key>               Clear an override, reverting to the default.
          reset <key>               Same as unset.
          reset --all --yes         Clear every override.
          describe <key> [--json]   Full metadata: type, allowed values, default, backend.
          export [--json] [--out f] Dump current settings (secrets omitted).
          import <file>             Apply a settings file (validated atomically).
          shortcuts <subcommand>    Manage keyboard shortcuts (list/get/set/unset/reset).

        Discover keys with `cmux settings list --keys`, inspect one with
        `cmux settings describe <key>`. Secret values are redacted on read.

        GUI subcommands:
          open [target]       Open Settings, optionally to a target section.
          path                Print cmux.json paths, docs URL, and schema URL.
          docs                Print the same output as `cmux docs settings`.

        Targets:
          account, app, terminal, sidebar-appearance, custom-sidebars,
          automation, browser, browser-import, global-hotkey,
          keyboard-shortcuts, shortcuts, workspace-colors, cmux-json,
          json, reset

        Config file:
          \(Self.primarySettingsDisplayPath)
          legacy config: \(Self.legacySettingsDisplayPath)
          legacy app support: \(Self.fallbackSettingsDisplayPath)

        Related (not cmux-owned, but cmux reads it for terminal behavior):
          \(Self.ghosttyConfigDisplayPath)

        Before editing cmux.json:
          Back up any existing cmux.json file to a timestamped .bak copy so the user can revert.

        Reload after editing cmux.json or Ghostty config:
          cmux reload-config   (reloads BOTH and refreshes terminals; no app restart needed)
        """
    }

    static let settingsShortcutsUsage = """
    cmux settings shortcuts — view and remap keyboard shortcuts

    Usage:
      cmux settings shortcuts list [--json]              Every action with its binding and default.
      cmux settings shortcuts get <action> [--json]      One action's current binding.
      cmux settings shortcuts set <action> <combo>       Bind, e.g. set newTab "cmd+t" or a chord "ctrl+b c".
                                          [--force]       Reassign a binding already used by another action.
      cmux settings shortcuts unset <action>             Revert an action to its default.
      cmux settings shortcuts reset                      Clear every shortcut override.

    (Bare `cmux settings shortcuts` opens the Settings window to Keyboard Shortcuts.)
    """
}
