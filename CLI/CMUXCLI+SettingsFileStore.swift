import Foundation
import CMUXSettingsCore

extension CMUXCLI {
    enum ImportOperation {
        case setting(String, Any)
        case shortcut(String, String)
    }

    struct SettingsFileStore {
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
                guard let definition = CmuxSettingsRegistry.shortcutActionsByName[rawAction]
                    ?? CmuxSettingsRegistry.shortcutActionsByName[rawAction.lowercased()] else {
                    continue
                }
                let shortcut = try CLIShortcut.parseJSONValue(rawValue, action: definition)
                result[definition.action] = shortcut.configString
            }
            return result
        }

        func conflictingShortcutAction(
            for proposed: CLIShortcut,
            action proposedAction: CmuxSettingsRegistry.ShortcutActionDefinition,
            root: [String: Any],
            skipCurrentShortcutCheck: Bool = false
        ) throws -> String? {
            let current = try resolvedShortcut(for: proposedAction, root: root).shortcut
            if !skipCurrentShortcutCheck && proposed == current {
                return nil
            }
            for definition in CmuxSettingsRegistry.shortcutActions where definition.action != proposedAction.action {
                guard definition.context.overlaps(proposedAction.context) else {
                    continue
                }
                let configured = try resolvedShortcut(for: definition, root: root).shortcut
                guard configured.conflicts(with: proposed, lhsNumbered: definition.usesNumberedDigitMatching, rhsNumbered: proposedAction.usesNumberedDigitMatching) else {
                    continue
                }
                return definition.action
            }
            return nil
        }

        func validateShortcutConflicts(
            for definitions: [CmuxSettingsRegistry.ShortcutActionDefinition],
            root: [String: Any]
        ) throws {
            for definition in definitions.sorted(by: { $0.action < $1.action }) {
                let shortcut = try resolvedShortcut(for: definition, root: root).shortcut
                if let conflict = try conflictingShortcutAction(
                    for: shortcut,
                    action: definition,
                    root: root,
                    skipCurrentShortcutCheck: true
                ) {
                    throw CLIError(message: "Shortcut '\(shortcut.configString)' for \(definition.action) conflicts with \(conflict)")
                }
            }
        }

        func validatedImportOperations(from root: [String: Any]) throws -> [ImportOperation] {
            let flat = flatten(root)
            var operations: [ImportOperation] = []
            var knownIntermediateKeys = Set<String>()
            for key in CmuxSettingsRegistry.sortedKeys + ["shortcuts.bindings"] {
                let components = key.split(separator: ".").map(String.init)
                guard components.count > 1 else { continue }
                for depth in 1..<components.count {
                    knownIntermediateKeys.insert(components.prefix(depth).joined(separator: "."))
                }
            }
            knownIntermediateKeys.insert("shortcuts.bindings")

            var shortcutImportKeysByAction: [String: String] = [:]
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
                    if let previousKey = shortcutImportKeysByAction[definition.action] {
                        throw CLIError(
                            message: "Duplicate shortcut action '\(definition.action)' in import: '\(previousKey)' and '\(key)'"
                        )
                    }
                    shortcutImportKeysByAction[definition.action] = key
                    let shortcut = try CLIShortcut.parseJSONValue(value, action: definition)
                    operations.append(.shortcut(definition.action, shortcut.configString))
                    continue
                }
                if knownIntermediateKeys.contains(key) {
                    if let dictionary = value as? [String: Any], dictionary.isEmpty {
                        continue
                    }
                    throw CLIError(message: "Invalid value for intermediate key '\(key)': expected an object")
                }
                throw CLIError(message: "Unknown setting key '\(key)'")
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

        func tomlString(from root: [String: Any]) throws -> String {
            try flatten(root)
                .sorted { $0.key < $1.key }
                .map { key, value in "\(key) = \(try tomlLiteral(value))" }
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

        private func tomlLiteral(_ value: Any) throws -> String {
            if value is NSNull {
                throw CLIError(message: "TOML format does not support null values; use --format json for settings with null values")
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
            if value is [String: Any] || value is NSDictionary {
                throw CLIError(message: "TOML format does not support object values; use --format json for settings with object values")
            }
            if value is [Any] || value is NSArray {
                throw CLIError(message: "TOML format does not support complex array values; use --format json for settings with complex array values")
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
                    if raw.hasPrefix("{"), raw.contains("=") {
                        throw CLIError(
                            message: "Unsupported TOML inline table literal: \(raw). Use dotted TOML keys or --format json."
                        )
                    }
                    throw CLIError(
                        message: "Invalid TOML array/object literal: \(raw). Use JSON-style arrays/objects or --format json."
                    )
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
}
