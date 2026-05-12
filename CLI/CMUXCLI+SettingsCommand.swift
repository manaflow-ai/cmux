import Darwin
import Foundation
import CMUXSettingsCore

extension CMUXCLI {
    enum SettingsCommand {
        static let subcommands: Set<String> = [
            "help", "list", "get", "set", "unset", "reset", "export", "import", "shortcuts",
        ]

        static let noSocketSubcommands: Set<String> = [
            "help", "list", "get", "export",
        ]
    }

    func isSettingsManagementSubcommand(_ subcommand: String) -> Bool {
        SettingsCommand.subcommands.contains(subcommand)
    }

    func settingsManagementCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let subcommand = parsedArgs.arguments.first?.lowercased() ?? "open"
        if subcommand == "shortcuts" {
            let nested = parsedArgs.arguments.dropFirst().first?.lowercased() ?? "list"
            return ["list", "get"].contains(nested)
        }
        return SettingsCommand.noSocketSubcommands.contains(subcommand)
    }

    func runSettingsManagementCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let wantsJSON = jsonOutput || parsedArgs.head.contains("--json")
        var args = parsedArgs.arguments
        guard let subcommand = args.first?.lowercased() else {
            throw CLIError(message: "Usage: cmux settings <subcommand>")
        }
        args.removeFirst()

        let store = SettingsFileStore()

        switch subcommand {
        case "help":
            print(settingsUsage())
        case "list":
            try runSettingsList(args: args, store: store, jsonOutput: wantsJSON)
        case "get":
            try runSettingsGet(args: args, store: store, jsonOutput: wantsJSON)
        case "set":
            try runSettingsSet(args: args, store: store)
            try reloadSettingsIfRunning(socketPath: socketPath, explicitPassword: explicitPassword)
        case "unset":
            try runSettingsUnset(args: args, store: store)
            try reloadSettingsIfRunning(socketPath: socketPath, explicitPassword: explicitPassword)
        case "reset":
            try runSettingsReset(args: args, store: store)
            try reloadSettingsIfRunning(socketPath: socketPath, explicitPassword: explicitPassword)
        case "export":
            try runSettingsExport(args: args, store: store)
        case "import":
            try runSettingsImport(args: args, store: store)
            try reloadSettingsIfRunning(socketPath: socketPath, explicitPassword: explicitPassword)
        case "shortcuts":
            try runSettingsShortcuts(args: args, store: store, socketPath: socketPath, explicitPassword: explicitPassword, jsonOutput: wantsJSON)
        default:
            throw CLIError(message: "Unknown settings subcommand '\(subcommand)'. Run 'cmux settings --help'.")
        }
    }

    private func runSettingsList(args: [String], store: SettingsFileStore, jsonOutput: Bool) throws {
        let keysOnly = args.contains("--keys")
        let remaining = args.filter { $0 != "--keys" }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux settings list [--keys] [--json]")
        }

        if keysOnly {
            print(CmuxSettingsRegistry.sortedKeys.joined(separator: "\n"))
            return
        }

        let root = try store.loadRoot()
        let rows = try CmuxSettingsRegistry.sortedKeys.map { key -> SettingsListRow in
            let definition = try CmuxSettingsRegistry.definition(for: key)
            let resolved = store.resolvedValue(for: definition, root: root)
            let presentedValue = store.presentedValue(resolved.value, for: definition, revealSensitive: false)
            let presentedDefault = store.presentedValue(definition.defaultValue, for: definition, revealSensitive: false)
            return SettingsListRow(
                key: definition.key,
                value: presentedValue.value,
                defaultValue: presentedDefault.value,
                source: resolved.source,
                redacted: presentedValue.redacted || presentedDefault.redacted
            )
        }

        if jsonOutput {
            print(jsonString([
                "settings": rows.map(\.payload),
                "path": store.displayPath,
            ]))
            return
        }

        for row in rows {
            print("\(row.key)\t\(store.displayString(row.value))\tdefault=\(store.displayString(row.defaultValue))\tsource=\(row.source)")
        }
    }

    private func runSettingsGet(args: [String], store: SettingsFileStore, jsonOutput: Bool) throws {
        let reveal = args.contains("--reveal")
        let remaining = args.filter { $0 != "--reveal" }
        guard remaining.count == 1, let key = remaining.first else {
            throw CLIError(message: "Usage: cmux settings get <key> [--json] [--reveal]")
        }
        let definition = try CmuxSettingsRegistry.definition(for: key)
        let root = try store.loadRoot()
        let resolved = store.resolvedValue(for: definition, root: root)
        let presented = store.presentedValue(resolved.value, for: definition, revealSensitive: reveal)

        if jsonOutput {
            print(jsonString([
                "key": definition.key,
                "value": presented.value,
                "default": definition.defaultValue,
                "source": resolved.source,
                "redacted": presented.redacted,
            ]))
        } else {
            print(store.displayString(presented.value))
        }
    }

    private func runSettingsSet(args: [String], store: SettingsFileStore) throws {
        guard args.count == 2 else {
            throw CLIError(message: "Usage: cmux settings set <key> <value>")
        }
        let key = args[0]
        let definition = try CmuxSettingsRegistry.definition(for: key)
        let value = try CmuxSettingsRegistry.normalizeCommandLineValue(args[1], for: definition)
        var root = try store.loadRoot()
        store.setValue(value, forPath: definition.key, in: &root)
        try store.save(root)
        print("OK")
    }

    private func runSettingsUnset(args: [String], store: SettingsFileStore) throws {
        guard args.count == 1, let key = args.first else {
            throw CLIError(message: "Usage: cmux settings unset <key>")
        }
        let definition = try CmuxSettingsRegistry.definition(for: key)
        var root = try store.loadRoot()
        store.removeValue(forPath: definition.key, in: &root)
        try store.save(root)
        print("OK")
    }

    private func runSettingsReset(args: [String], store: SettingsFileStore) throws {
        let yes = args.contains("--yes")
        let remaining = args.filter { $0 != "--yes" }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux settings reset [--yes]")
        }
        if !yes {
            print("Reset all cmux settings and shortcuts in \(store.displayPath)? Type 'yes' to continue: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" else {
                throw CLIError(message: "settings reset cancelled")
            }
        }

        var root = try store.loadRoot()
        for key in CmuxSettingsRegistry.sortedKeys {
            store.removeValue(forPath: key, in: &root)
        }
        store.removeValue(forPath: "shortcuts.bindings", in: &root)
        try store.save(root)
        print("OK")
    }

    private func runSettingsExport(args: [String], store: SettingsFileStore) throws {
        var format = "json"
        var outputPath: String?
        var revealSensitive = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--format":
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw CLIError(message: "cmux settings export --format requires json or toml")
                }
                format = args[valueIndex].lowercased()
                index += 2
            case "--out":
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw CLIError(message: "cmux settings export --out requires a file")
                }
                outputPath = args[valueIndex]
                index += 2
            case "--reveal":
                revealSensitive = true
                index += 1
            default:
                throw CLIError(message: "Usage: cmux settings export [--format json|toml] [--out <file>] [--reveal]")
            }
        }

        let root = try store.loadRoot()
        var exportRoot: [String: Any] = [:]
        for key in CmuxSettingsRegistry.sortedKeys {
            let definition = try CmuxSettingsRegistry.definition(for: key)
            let resolved = store.resolvedValue(for: definition, root: root)
            guard resolved.source == "cmux.json" else { continue }
            guard revealSensitive || !definition.isSensitive else { continue }
            store.setValue(resolved.value, forPath: key, in: &exportRoot)
        }
        let shortcutBindings = try store.configuredShortcutBindings(root: root)
        if !shortcutBindings.isEmpty {
            store.setValue(shortcutBindings, forPath: "shortcuts.bindings", in: &exportRoot)
        }

        let output: String
        switch format {
        case "json":
            output = jsonString(exportRoot) + "\n"
        case "toml":
            output = try store.tomlString(from: exportRoot)
        default:
            throw CLIError(message: "cmux settings export --format must be json or toml")
        }

        if let outputPath {
            let url = URL(fileURLWithPath: store.absolutePath(outputPath))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try output.write(to: url, atomically: true, encoding: .utf8)
        } else {
            print(output, terminator: "")
        }
    }

    private func runSettingsImport(args: [String], store: SettingsFileStore) throws {
        guard args.count == 1, let path = args.first else {
            throw CLIError(message: "Usage: cmux settings import <file>")
        }
        let importRoot = try store.loadImportRoot(path: path)
        let operations = try store.validatedImportOperations(from: importRoot)

        var root = try store.loadRoot()
        var importedShortcutActions: [String: CmuxSettingsRegistry.ShortcutActionDefinition] = [:]
        for operation in operations {
            switch operation {
            case let .setting(key, value):
                store.setValue(value, forPath: key, in: &root)
            case let .shortcut(action, shortcut):
                let definition = try CmuxSettingsRegistry.shortcutAction(for: action)
                let parsedShortcut = try CLIShortcut.parse(shortcut, action: definition)
                store.setValue(parsedShortcut.configString, forPath: "shortcuts.bindings.\(action)", in: &root)
                importedShortcutActions[definition.action] = definition
            }
        }
        try store.validateShortcutConflicts(for: Array(importedShortcutActions.values), root: root)
        try store.save(root)
        print("OK")
    }

    private func runSettingsShortcuts(
        args: [String],
        store: SettingsFileStore,
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        var args = args
        let subcommand = args.first?.lowercased() ?? "list"
        if !args.isEmpty {
            args.removeFirst()
        }

        switch subcommand {
        case "list":
            try runSettingsShortcutsList(args: args, store: store, jsonOutput: jsonOutput)
        case "get":
            try runSettingsShortcutsGet(args: args, store: store, jsonOutput: jsonOutput)
        case "set":
            try runSettingsShortcutsSet(args: args, store: store)
            try reloadSettingsIfRunning(socketPath: socketPath, explicitPassword: explicitPassword)
        case "unset":
            try runSettingsShortcutsUnset(args: args, store: store)
            try reloadSettingsIfRunning(socketPath: socketPath, explicitPassword: explicitPassword)
        case "reset":
            try runSettingsShortcutsReset(args: args, store: store)
            try reloadSettingsIfRunning(socketPath: socketPath, explicitPassword: explicitPassword)
        default:
            throw CLIError(message: "Unknown settings shortcuts subcommand '\(subcommand)'. Run 'cmux settings --help'.")
        }
    }

    private func runSettingsShortcutsList(args: [String], store: SettingsFileStore, jsonOutput: Bool) throws {
        let keysOnly = args.contains("--keys")
        let remaining = args.filter { $0 != "--keys" }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux settings shortcuts list [--keys] [--json]")
        }
        if keysOnly {
            print(CmuxSettingsRegistry.sortedShortcutActions.joined(separator: "\n"))
            return
        }
        let root = try store.loadRoot()
        let rows = try CmuxSettingsRegistry.sortedShortcutActions.map { action -> ShortcutListRow in
            let definition = try CmuxSettingsRegistry.shortcutAction(for: action)
            let resolved = try store.resolvedShortcut(for: definition, root: root)
            return ShortcutListRow(
                action: definition.action,
                label: definition.label,
                context: definition.context.rawValue,
                value: resolved.shortcut.configString,
                defaultValue: definition.defaultValue,
                source: resolved.source
            )
        }
        if jsonOutput {
            print(jsonString([
                "shortcuts": rows.map(\.payload),
                "path": store.displayPath,
            ]))
        } else {
            for row in rows {
                print("\(row.action)\t\(row.value)\tdefault=\(row.defaultValue)\tsource=\(row.source)")
            }
        }
    }

    private func runSettingsShortcutsGet(args: [String], store: SettingsFileStore, jsonOutput: Bool) throws {
        guard args.count == 1, let rawAction = args.first else {
            throw CLIError(message: "Usage: cmux settings shortcuts get <action>")
        }
        let definition = try CmuxSettingsRegistry.shortcutAction(for: rawAction)
        let root = try store.loadRoot()
        let resolved = try store.resolvedShortcut(for: definition, root: root)
        if jsonOutput {
            print(jsonString([
                "action": definition.action,
                "context": definition.context.rawValue,
                "value": resolved.shortcut.configString,
                "default": definition.defaultValue,
                "source": resolved.source,
            ]))
        } else {
            print(resolved.shortcut.configString)
        }
    }

    private func runSettingsShortcutsSet(args: [String], store: SettingsFileStore) throws {
        let force = args.contains("--force")
        let remaining = args.filter { $0 != "--force" }
        guard remaining.count == 2 else {
            throw CLIError(message: "Usage: cmux settings shortcuts set <action> <key-combo> [--force]")
        }
        let definition = try CmuxSettingsRegistry.shortcutAction(for: remaining[0])
        let shortcut = try CLIShortcut.parse(remaining[1], action: definition)
        var root = try store.loadRoot()
        if let conflict = try store.conflictingShortcutAction(for: shortcut, action: definition, root: root) {
            if !force {
                throw CLIError(message: "Shortcut '\(shortcut.configString)' for \(definition.action) conflicts with \(conflict)")
            }
            store.setValue(CLIShortcut.unbound.configString, forPath: "shortcuts.bindings.\(conflict)", in: &root)
        }
        store.setValue(shortcut.configString, forPath: "shortcuts.bindings.\(definition.action)", in: &root)
        try store.save(root)
        print("OK")
    }

    private func runSettingsShortcutsUnset(args: [String], store: SettingsFileStore) throws {
        guard args.count == 1, let rawAction = args.first else {
            throw CLIError(message: "Usage: cmux settings shortcuts unset <action>")
        }
        let definition = try CmuxSettingsRegistry.shortcutAction(for: rawAction)
        var root = try store.loadRoot()
        store.removeValue(forPath: "shortcuts.bindings.\(definition.action)", in: &root)
        try store.save(root)
        print("OK")
    }

    private func runSettingsShortcutsReset(args: [String], store: SettingsFileStore) throws {
        guard args.isEmpty else {
            throw CLIError(message: "Usage: cmux settings shortcuts reset")
        }
        var root = try store.loadRoot()
        store.removeValue(forPath: "shortcuts.bindings", in: &root)
        try store.save(root)
        print("OK")
    }

    private func reloadSettingsIfRunning(socketPath: String, explicitPassword: String?) throws {
        guard socketExists(at: socketPath) else { return }
        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: false
        )
        defer { client.close() }
        let response = try client.send(command: "reload_config")
        if response.hasPrefix("ERROR:") {
            throw CLIError(message: "settings updated, but live reload failed: \(response)")
        }
    }

    private func socketExists(at path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private struct SettingsListRow {
        let key: String
        let value: Any
        let defaultValue: Any
        let source: String
        let redacted: Bool

        var payload: [String: Any] {
            [
                "key": key,
                "value": value,
                "default": defaultValue,
                "source": source,
                "redacted": redacted,
            ]
        }
    }

    private struct ShortcutListRow {
        let action: String
        let label: String
        let context: String
        let value: String
        let defaultValue: String
        let source: String

        var payload: [String: Any] {
            [
                "action": action,
                "label": label,
                "context": context,
                "value": value,
                "default": defaultValue,
                "source": source,
            ]
        }
    }
}
