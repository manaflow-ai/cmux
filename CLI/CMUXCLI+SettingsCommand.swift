import Darwin
import Foundation

extension CMUXCLI {
    enum SettingsCommand {
        static let subcommands: Set<String> = [
            "list", "get", "set", "unset", "reset", "export", "import", "shortcuts",
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
        let wantsJSON = jsonOutput || parsedArgs.head.contains("--json") || parsedArgs.arguments.contains("--json")
        var args = parsedArgs.arguments.filter { $0 != "--json" }
        let subcommand = args.first?.lowercased() ?? "list"
        if !args.isEmpty {
            args.removeFirst()
        }

        let store = SettingsFileStore()

        switch subcommand {
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
            output = store.tomlString(from: exportRoot)
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
        for operation in operations {
            switch operation {
            case let .setting(key, value):
                store.setValue(value, forPath: key, in: &root)
            case let .shortcut(action, shortcut):
                store.setValue(shortcut, forPath: "shortcuts.bindings.\(action)", in: &root)
            }
        }
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
        if !force, let conflict = try store.conflictingShortcutAction(for: shortcut, action: definition, root: root) {
            throw CLIError(message: "Shortcut '\(shortcut.configString)' for \(definition.action) conflicts with \(conflict)")
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
        let value: String
        let defaultValue: String
        let source: String

        var payload: [String: Any] {
            [
                "action": action,
                "label": label,
                "value": value,
                "default": defaultValue,
                "source": source,
            ]
        }
    }

    private enum ImportOperation {
        case setting(String, Any)
        case shortcut(String, String)
    }

    private struct SettingsFileStore {
        private static let sensitivePlaceholder = "<redacted>"

        let fileManager = FileManager.default

        var configURL: URL {
            URL(fileURLWithPath: absolutePath("~/.config/cmux/cmux.json"))
        }

        var displayPath: String { "~/.config/cmux/cmux.json" }

        func loadRoot() throws -> [String: Any] {
            guard fileManager.fileExists(atPath: configURL.path) else {
                return [:]
            }
            let data = try Data(contentsOf: configURL)
            guard !data.isEmpty else { return [:] }
            let sanitized = try JSONCParser.preprocess(data: data)
            let object = try JSONSerialization.jsonObject(with: sanitized)
            guard let root = object as? [String: Any] else {
                throw CLIError(message: "\(displayPath) must contain a JSON object")
            }
            return root
        }

        func save(_ root: [String: Any]) throws {
            guard JSONSerialization.isValidJSONObject(root) else {
                throw CLIError(message: "Refusing to write invalid cmux.json object")
            }
            try fileManager.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: configURL, options: .atomic)
        }

        func loadImportRoot(path: String) throws -> [String: Any] {
            let absolute = absolutePath(path)
            let data = try Data(contentsOf: URL(fileURLWithPath: absolute))
            if absolute.lowercased().hasSuffix(".toml") {
                return try parseToml(data: data)
            }
            let sanitized = try JSONCParser.preprocess(data: data)
            let object = try JSONSerialization.jsonObject(with: sanitized)
            guard let root = object as? [String: Any] else {
                throw CLIError(message: "cmux settings import requires a JSON or TOML object")
            }
            return root
        }

        func resolvedValue(for definition: CmuxSettingsRegistry.SettingDefinition, root: [String: Any]) -> (value: Any, source: String) {
            if let value = value(forPath: definition.key, in: root) {
                return (value, "cmux.json")
            }
            return (definition.defaultValue, "default")
        }

        func resolvedShortcut(
            for definition: CmuxSettingsRegistry.ShortcutActionDefinition,
            root: [String: Any]
        ) throws -> (shortcut: CLIShortcut, source: String) {
            if let raw = value(forPath: "shortcuts.bindings.\(definition.action)", in: root) {
                let shortcut = try CLIShortcut.parseJSONValue(raw, action: definition)
                return (shortcut, "cmux.json")
            }
            return (try CLIShortcut.parse(definition.defaultValue, action: definition), "default")
        }

        func configuredShortcutBindings(root: [String: Any]) throws -> [String: String] {
            guard let rawBindings = value(forPath: "shortcuts.bindings", in: root) else {
                return [:]
            }
            guard let bindings = rawBindings as? [String: Any] else {
                throw CLIError(message: "shortcuts.bindings expects an object")
            }
            var result: [String: String] = [:]
            for (rawAction, rawValue) in bindings {
                let definition = try CmuxSettingsRegistry.shortcutAction(for: rawAction)
                let shortcut = try CLIShortcut.parseJSONValue(rawValue, action: definition)
                result[definition.action] = shortcut.configString
            }
            return result
        }

        func conflictingShortcutAction(
            for proposed: CLIShortcut,
            action proposedAction: CmuxSettingsRegistry.ShortcutActionDefinition,
            root: [String: Any]
        ) throws -> String? {
            let current = try resolvedShortcut(for: proposedAction, root: root).shortcut
            if proposed == current {
                return nil
            }
            for definition in CmuxSettingsRegistry.shortcutActions where definition.action != proposedAction.action {
                let configured = try resolvedShortcut(for: definition, root: root).shortcut
                guard configured.conflicts(with: proposed, lhsNumbered: definition.usesNumberedDigitMatching, rhsNumbered: proposedAction.usesNumberedDigitMatching) else {
                    continue
                }
                return definition.action
            }
            return nil
        }

        func validatedImportOperations(from root: [String: Any]) throws -> [ImportOperation] {
            let flat = flatten(root)
            var operations: [ImportOperation] = []
            var knownPrefixes = Set(CmuxSettingsRegistry.sortedKeys)
            knownPrefixes.insert("shortcuts.bindings")

            for (key, value) in flat.sorted(by: { $0.key < $1.key }) {
                if key == "schemaVersion" || key == "$schema" { continue }
                if key == "shortcuts.bindings", let dictionary = value as? [String: Any], dictionary.isEmpty {
                    continue
                }
                if let definition = CmuxSettingsRegistry.definitionsByKey[key] {
                    let normalized = try CmuxSettingsRegistry.normalizeJSONValue(value, for: definition)
                    operations.append(.setting(definition.key, normalized))
                    continue
                }
                if key.hasPrefix("shortcuts.bindings.") {
                    let actionRaw = String(key.dropFirst("shortcuts.bindings.".count))
                    let definition = try CmuxSettingsRegistry.shortcutAction(for: actionRaw)
                    let shortcut = try CLIShortcut.parseJSONValue(value, action: definition)
                    operations.append(.shortcut(definition.action, shortcut.configString))
                    continue
                }
                if !knownPrefixes.contains(where: { $0.hasPrefix("\(key).") }) {
                    throw CLIError(message: "Unknown setting key '\(key)'")
                }
            }
            return operations
        }

        func value(forPath path: String, in root: [String: Any]) -> Any? {
            let components = path.split(separator: ".").map(String.init)
            var current: Any = root
            for component in components {
                guard let dictionary = current as? [String: Any],
                      let next = dictionary[component] else {
                    return nil
                }
                current = next
            }
            return current
        }

        func setValue(_ value: Any, forPath path: String, in root: inout [String: Any]) {
            var components = path.split(separator: ".").map(String.init)
            guard let leaf = components.popLast() else { return }
            setValue(value, components: components, leaf: leaf, in: &root)
        }

        private func setValue(_ value: Any, components: [String], leaf: String, in root: inout [String: Any]) {
            guard let first = components.first else {
                root[leaf] = value
                return
            }
            var child = root[first] as? [String: Any] ?? [:]
            setValue(value, components: Array(components.dropFirst()), leaf: leaf, in: &child)
            root[first] = child
        }

        func removeValue(forPath path: String, in root: inout [String: Any]) {
            var components = path.split(separator: ".").map(String.init)
            guard let leaf = components.popLast() else { return }
            _ = removeValue(components: components, leaf: leaf, in: &root)
        }

        @discardableResult
        private func removeValue(components: [String], leaf: String, in root: inout [String: Any]) -> Bool {
            guard let first = components.first else {
                root.removeValue(forKey: leaf)
                return root.isEmpty
            }
            guard var child = root[first] as? [String: Any] else { return root.isEmpty }
            if removeValue(components: Array(components.dropFirst()), leaf: leaf, in: &child) {
                root.removeValue(forKey: first)
            } else {
                root[first] = child
            }
            return root.isEmpty
        }

        func displayString(_ value: Any) -> String {
            if value is NSNull {
                return "null"
            }
            if let string = value as? String {
                return string
            }
            if let bool = value as? Bool {
                return bool ? "true" : "false"
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            if JSONSerialization.isValidJSONObject([value]),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
               let output = String(data: data, encoding: .utf8) {
                return output
            }
            return String(describing: value)
        }

        func presentedValue(
            _ value: Any,
            for definition: CmuxSettingsRegistry.SettingDefinition,
            revealSensitive: Bool
        ) -> (value: Any, redacted: Bool) {
            guard definition.isSensitive,
                  !revealSensitive,
                  hasSensitivePayload(value) else {
                return (value, false)
            }
            return (Self.sensitivePlaceholder, true)
        }

        private func hasSensitivePayload(_ value: Any) -> Bool {
            if value is NSNull {
                return false
            }
            if let string = value as? String {
                return !string.isEmpty
            }
            return true
        }

        func tomlString(from root: [String: Any]) -> String {
            flatten(root)
                .sorted { $0.key < $1.key }
                .map { key, value in "\(key) = \(tomlLiteral(value))" }
                .joined(separator: "\n") + "\n"
        }

        func absolutePath(_ rawPath: String) -> String {
            if rawPath == "~" {
                return homeDirectory()
            }
            if rawPath.hasPrefix("~/") {
                return homeDirectory() + String(rawPath.dropFirst())
            }
            if rawPath.hasPrefix("/") {
                return rawPath
            }
            return URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent(rawPath)
                .standardizedFileURL
                .path
        }

        private func homeDirectory() -> String {
            ProcessInfo.processInfo.environment["HOME"]
                ?? fileManager.homeDirectoryForCurrentUser.path
        }

        private func flatten(_ root: [String: Any], prefix: String = "") -> [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in root {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                if let dictionary = value as? [String: Any],
                   !(value is NSNull),
                   !dictionary.isEmpty,
                   CmuxSettingsRegistry.definitionsByKey[path] == nil {
                    result.merge(flatten(dictionary, prefix: path), uniquingKeysWith: { _, rhs in rhs })
                } else {
                    result[path] = value
                }
            }
            return result
        }

        private func tomlLiteral(_ value: Any) -> String {
            if value is NSNull {
                return "null"
            }
            if let bool = value as? Bool {
                return bool ? "true" : "false"
            }
            if let number = value as? NSNumber, !(value is Bool) {
                return number.stringValue
            }
            if let string = value as? String {
                return "\"\(escapeToml(string))\""
            }
            if let values = value as? [String] {
                return "[" + values.map { "\"\(escapeToml($0))\"" }.joined(separator: ", ") + "]"
            }
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return "\"\(escapeToml(String(describing: value)))\""
        }

        private func escapeToml(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }

        private func parseToml(data: Data) throws -> [String: Any] {
            guard let source = String(data: data, encoding: .utf8) else {
                throw CLIError(message: "TOML import must be UTF-8")
            }
            var root: [String: Any] = [:]
            var tablePath: [String] = []
            for rawLine in source.components(separatedBy: .newlines) {
                let line = stripTomlComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                if line.hasPrefix("[") {
                    guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                        throw CLIError(message: "Unsupported TOML section line: \(rawLine)")
                    }
                    let header = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    tablePath = try parseTomlKeyPath(header, rawLine: rawLine)
                    continue
                }
                guard let equals = line.firstIndex(of: "=") else {
                    throw CLIError(message: "Invalid TOML line: \(rawLine)")
                }
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                let literal = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let keyPath = tablePath + (try parseTomlKeyPath(key, rawLine: rawLine))
                let value = try parseTomlLiteral(String(literal))
                setValue(value, forPath: keyPath.joined(separator: "."), in: &root)
            }
            return root
        }

        private func parseTomlKeyPath(_ raw: String, rawLine: String) throws -> [String] {
            let components = raw
                .split(separator: ".", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty }) else {
                throw CLIError(message: "Invalid TOML key path: \(rawLine)")
            }
            return components
        }

        private func stripTomlComment(_ rawLine: String) -> String {
            var inString = false
            var escaped = false
            for index in rawLine.indices {
                let character = rawLine[index]
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" && inString {
                    escaped = true
                    continue
                }
                if character == "\"" {
                    inString.toggle()
                    continue
                }
                if character == "#", !inString {
                    return String(rawLine[..<index])
                }
            }
            return rawLine
        }

        private func parseTomlLiteral(_ raw: String) throws -> Any {
            if raw == "true" { return true }
            if raw == "false" { return false }
            if raw == "null" { return NSNull() }
            if let int = Int(raw) { return int }
            if let double = Double(raw) { return double }
            if raw.hasPrefix("[") || raw.hasPrefix("{") {
                guard let data = raw.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    throw CLIError(message: "Invalid TOML JSON literal: \(raw)")
                }
                return value
            }
            if raw.hasPrefix("\""), raw.hasSuffix("\"") {
                let inner = raw.dropFirst().dropLast()
                return try unescapeTomlString(String(inner))
            }
            return raw
        }

        private func unescapeTomlString(_ raw: String) throws -> String {
            var output = ""
            var index = raw.startIndex
            while index < raw.endIndex {
                let character = raw[index]
                guard character == "\\" else {
                    output.append(character)
                    index = raw.index(after: index)
                    continue
                }
                let escapeIndex = raw.index(after: index)
                guard escapeIndex < raw.endIndex else {
                    throw CLIError(message: "Invalid TOML string escape")
                }
                switch raw[escapeIndex] {
                case "n":
                    output.append("\n")
                case "\"":
                    output.append("\"")
                case "\\":
                    output.append("\\")
                default:
                    throw CLIError(message: "Unsupported TOML string escape: \\\(raw[escapeIndex])")
                }
                index = raw.index(after: escapeIndex)
            }
            return output
        }
    }

    private struct CLIShortcut: Equatable {
        let strokes: [CLIShortcutStroke]
        let isUnbound: Bool

        static let unbound = CLIShortcut(strokes: [], isUnbound: true)

        var configString: String {
            if isUnbound {
                return "none"
            }
            return strokes.map(\.configString).joined(separator: ", ")
        }

        static func parseJSONValue(
            _ value: Any,
            action: CmuxSettingsRegistry.ShortcutActionDefinition
        ) throws -> CLIShortcut {
            if value is NSNull {
                return .unbound
            }
            if let string = value as? String {
                return try parse(string, action: action)
            }
            if let strings = value as? [String] {
                return try parse(strokes: strings, action: action)
            }
            throw CLIError(message: "Shortcut for \(action.action) must be a string, string array, or null")
        }

        static func parse(_ raw: String, action: CmuxSettingsRegistry.ShortcutActionDefinition) throws -> CLIShortcut {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["", "none", "clear", "unbound", "disabled"].contains(trimmed.lowercased()) {
                return .unbound
            }
            if let value = CmuxSettingsRegistry.parseJSONLiteral(trimmed) {
                return try parseJSONValue(value, action: action)
            }
            return try parse(strokes: splitChordString(trimmed), action: action)
        }

        static func parse(strokes rawStrokes: [String], action: CmuxSettingsRegistry.ShortcutActionDefinition) throws -> CLIShortcut {
            guard (1...2).contains(rawStrokes.count) else {
                throw CLIError(message: "Shortcut for \(action.action) must have one stroke or a two-stroke chord")
            }
            let strokes = try rawStrokes.map { try CLIShortcutStroke.parse($0) }
            var shortcut = CLIShortcut(strokes: strokes, isUnbound: false)
            if action.action == "showHideAllWindows" {
                guard shortcut.strokes.count == 1 else {
                    throw CLIError(message: "Global hotkey shortcut cannot be a chord")
                }
                guard shortcut.strokes[0].hasModifier else {
                    throw CLIError(message: "Global hotkey shortcut must include a modifier")
                }
            }
            if action.usesNumberedDigitMatching {
                guard let last = shortcut.strokes.last, last.isDigit else {
                    throw CLIError(message: "\(action.action) shortcut must use a digit 1-9")
                }
                shortcut = CLIShortcut(
                    strokes: Array(shortcut.strokes.dropLast()) + [last.normalizedNumberedDigit],
                    isUnbound: false
                )
            }
            return shortcut
        }

        private static func splitChordString(_ raw: String) -> [String] {
            var strokes: [String] = []
            var strokeStart = raw.startIndex
            var index = raw.startIndex
            while index < raw.endIndex {
                guard raw[index] == "," else {
                    index = raw.index(after: index)
                    continue
                }

                let next = raw.index(after: index)
                guard next < raw.endIndex, raw[next].isWhitespace else {
                    index = next
                    continue
                }

                strokes.append(String(raw[strokeStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                var nextStrokeStart = next
                while nextStrokeStart < raw.endIndex, raw[nextStrokeStart].isWhitespace {
                    nextStrokeStart = raw.index(after: nextStrokeStart)
                }
                strokeStart = nextStrokeStart
                index = nextStrokeStart
            }

            strokes.append(String(raw[strokeStart..<raw.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines))
            return strokes
        }

        func conflicts(
            with other: CLIShortcut,
            lhsNumbered: Bool,
            rhsNumbered: Bool
        ) -> Bool {
            guard !isUnbound, !other.isUnbound else { return false }
            switch (strokes.count, other.strokes.count) {
            case (1, 1):
                return strokes[0].conflicts(with: other.strokes[0], lhsNumbered: lhsNumbered, rhsNumbered: rhsNumbered)
            case (2, 2):
                return strokes[0].exactlyConflicts(with: other.strokes[0]) &&
                    strokes[1].conflicts(with: other.strokes[1], lhsNumbered: lhsNumbered, rhsNumbered: rhsNumbered)
            case (2, 1):
                return strokes[0].conflicts(with: other.strokes[0], lhsNumbered: false, rhsNumbered: rhsNumbered)
            case (1, 2):
                return strokes[0].conflicts(with: other.strokes[0], lhsNumbered: lhsNumbered, rhsNumbered: false)
            default:
                return false
            }
        }
    }

    private struct CLIShortcutStroke: Equatable {
        let key: String
        let command: Bool
        let shift: Bool
        let option: Bool
        let control: Bool

        var hasModifier: Bool { command || shift || option || control }
        var isDigit: Bool { Int(key).map { (1...9).contains($0) } ?? false }
        var normalizedNumberedDigit: CLIShortcutStroke {
            CLIShortcutStroke(key: "1", command: command, shift: shift, option: option, control: control)
        }

        var configString: String {
            var tokens: [String] = []
            if command { tokens.append("cmd") }
            if shift { tokens.append("shift") }
            if option { tokens.append("option") }
            if control { tokens.append("ctrl") }
            tokens.append(displayKey)
            return tokens.joined(separator: "+")
        }

        var displayKey: String {
            switch key {
            case "\r": return "return"
            case "\t": return "tab"
            case " ": return "space"
            case "←": return "left"
            case "→": return "right"
            case "↑": return "up"
            case "↓": return "down"
            default: return key
            }
        }

        static func parse(_ raw: String) throws -> CLIShortcutStroke {
            let pieces = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "+", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !pieces.isEmpty else {
                throw CLIError(message: "Shortcut is empty")
            }
            var command = false
            var shift = false
            var option = false
            var control = false
            var keyPieces: [String] = []
            for piece in pieces {
                switch piece.lowercased() {
                case "cmd", "command", "⌘":
                    command = true
                case "shift", "⇧":
                    shift = true
                case "option", "opt", "alt", "⌥":
                    option = true
                case "ctrl", "control", "^":
                    control = true
                default:
                    keyPieces.append(piece)
                }
            }
            guard keyPieces.count == 1, let rawKey = keyPieces.first else {
                throw CLIError(message: "Shortcut '\(raw)' must contain exactly one key")
            }
            guard command || shift || option || control else {
                throw CLIError(message: "Shortcut '\(raw)' must include a modifier")
            }
            guard let key = normalizedKey(rawKey) else {
                throw CLIError(message: "Shortcut key '\(rawKey)' is not supported")
            }
            return CLIShortcutStroke(key: key, command: command, shift: shift, option: option, control: control)
        }

        static func normalizedKey(_ raw: String) -> String? {
            if raw.isEmpty {
                return nil
            }
            switch raw.lowercased() {
            case "return", "enter":
                return "\r"
            case "tab":
                return "\t"
            case "space", "spacebar":
                return " "
            case "left", "arrowleft":
                return "←"
            case "right", "arrowright":
                return "→"
            case "up", "arrowup":
                return "↑"
            case "down", "arrowdown":
                return "↓"
            case "escape", "esc":
                return "\u{1B}"
            default:
                return raw.count == 1 ? raw.lowercased() : nil
            }
        }

        func conflicts(
            with other: CLIShortcutStroke,
            lhsNumbered: Bool,
            rhsNumbered: Bool
        ) -> Bool {
            if lhsNumbered || rhsNumbered {
                guard isDigit, other.isDigit else { return false }
                return command == other.command &&
                    shift == other.shift &&
                    option == other.option &&
                    control == other.control
            }
            return exactlyConflicts(with: other)
        }

        func exactlyConflicts(with other: CLIShortcutStroke) -> Bool {
            key == other.key &&
                command == other.command &&
                shift == other.shift &&
                option == other.option &&
                control == other.control
        }
    }
}
