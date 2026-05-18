import Foundation
import CMUXSettingsCore

extension CMUXCLI {
    enum ImportOperation {
        case setting(String, Any)
        case shortcut(CmuxSettingsRegistry.ShortcutActionDefinition, String)
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

        func resolvedShortcutForDisplay(
            for definition: CmuxSettingsRegistry.ShortcutActionDefinition,
            root: [String: Any]
        ) throws -> (value: Any, source: String, error: String?) {
            if let raw = value(forPath: "shortcuts.bindings.\(definition.action)", in: root) {
                do {
                    let shortcut = try CLIShortcut.parseJSONValue(raw, action: definition)
                    return (shortcut.configString, "cmux.json", nil)
                } catch {
                    return (raw, "invalid", String(describing: error))
                }
            }
            let shortcut = try CLIShortcut.parse(definition.defaultValue, action: definition)
            return (shortcut.configString, "default", nil)
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
                guard let shortcut = try? CLIShortcut.parseJSONValue(rawValue, action: definition) else {
                    continue
                }
                result[definition.action] = shortcut.configString
            }
            return result
        }

        func conflictingShortcutActions(
            for proposed: CLIShortcut,
            action proposedAction: CmuxSettingsRegistry.ShortcutActionDefinition,
            root: [String: Any]
        ) throws -> [String] {
            var conflicts: [String] = []
            for definition in CmuxSettingsRegistry.shortcutActions where definition.action != proposedAction.action {
                guard definition.context.overlaps(proposedAction.context) else {
                    continue
                }
                let configured = try resolvedShortcutForConflictScan(for: definition, root: root)
                guard configured.conflicts(with: proposed, lhsNumbered: definition.usesNumberedDigitMatching, rhsNumbered: proposedAction.usesNumberedDigitMatching) else {
                    continue
                }
                conflicts.append(definition.action)
            }
            return conflicts
        }

        private func resolvedShortcutForConflictScan(
            for definition: CmuxSettingsRegistry.ShortcutActionDefinition,
            root: [String: Any]
        ) throws -> CLIShortcut {
            if let raw = value(forPath: "shortcuts.bindings.\(definition.action)", in: root) {
                do {
                    return try CLIShortcut.parseJSONValue(raw, action: definition)
                } catch {
                    return try CLIShortcut.parse(definition.defaultValue, action: definition)
                }
            }
            return try CLIShortcut.parse(definition.defaultValue, action: definition)
        }

        func validateShortcutConflicts(
            for definitions: [CmuxSettingsRegistry.ShortcutActionDefinition],
            root: [String: Any]
        ) throws {
            for definition in definitions.sorted(by: { $0.action < $1.action }) {
                let shortcut = try resolvedShortcut(for: definition, root: root).shortcut
                let conflicts = try conflictingShortcutActions(
                    for: shortcut,
                    action: definition,
                    root: root
                )
                if !conflicts.isEmpty {
                    throw CLIError(message: "Shortcut '\(shortcut.configString)' for \(definition.action) conflicts with \(conflicts.joined(separator: ", "))")
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
                    operations.append(.shortcut(definition, shortcut.configString))
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

        private func setTomlValue(
            _ value: Any,
            forComponents path: [String],
            lineNumber: Int,
            in root: inout [String: Any]
        ) throws {
            guard !path.isEmpty else { return }
            try setTomlValue(value, remaining: path, prefix: [], lineNumber: lineNumber, in: &root)
        }

        private func setTomlValue(
            _ value: Any,
            remaining: [String],
            prefix: [String],
            lineNumber: Int,
            in root: inout [String: Any]
        ) throws {
            let key = remaining[0]
            let currentPath = prefix + [key]
            if remaining.count == 1 {
                if root[key] is [String: Any] {
                    let pathDescription = currentPath.joined(separator: ".")
                    throw CLIError(
                        message: "TOML key '\(pathDescription)' on line \(lineNumber) conflicts with an existing table"
                    )
                }
                root[key] = value
                return
            }

            let remainingPath = currentPath + Array(remaining.dropFirst())
            if let existing = root[key] {
                guard var child = existing as? [String: Any] else {
                    let pathDescription = remainingPath.joined(separator: ".")
                    let scalarPathDescription = currentPath.joined(separator: ".")
                    throw CLIError(
                        message: "TOML key '\(pathDescription)' on line \(lineNumber) conflicts with scalar key '\(scalarPathDescription)'"
                    )
                }
                try setTomlValue(
                    value,
                    remaining: Array(remaining.dropFirst()),
                    prefix: currentPath,
                    lineNumber: lineNumber,
                    in: &child
                )
                root[key] = child
            } else {
                var child: [String: Any] = [:]
                try setTomlValue(
                    value,
                    remaining: Array(remaining.dropFirst()),
                    prefix: currentPath,
                    lineNumber: lineNumber,
                    in: &child
                )
                root[key] = child
            }
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
            if let bool = booleanValue(value) {
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
            try flattenForTomlExport(root)
                .sorted { tomlKeyPath($0.path) < tomlKeyPath($1.path) }
                .map { path, value in "\(tomlKeyPath(path)) = \(try tomlLiteral(value))" }
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

        private func flattenForTomlExport(_ root: [String: Any], prefix: [String] = []) -> [(path: [String], value: Any)] {
            var result: [(path: [String], value: Any)] = []
            for (key, value) in root {
                let path = prefix + [key]
                let registryKey = path.joined(separator: ".")
                if let dictionary = value as? [String: Any],
                   !dictionary.isEmpty,
                   CmuxSettingsRegistry.definitionsByKey[registryKey] == nil {
                    result.append(contentsOf: flattenForTomlExport(dictionary, prefix: path))
                } else {
                    result.append((path, value))
                }
            }
            return result
        }

        private func tomlKeyPath(_ path: [String]) -> String {
            path.map(tomlKey).joined(separator: ".")
        }

        private func tomlKey(_ value: String) -> String {
            guard isTomlBareKey(value) else {
                return "\"\(escapeToml(value))\""
            }
            return value
        }

        private func isTomlBareKey(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 48...57, 65...90, 95, 97...122, 45:
                    return true
                default:
                    return false
                }
            }
        }

        private func tomlLiteral(_ value: Any) throws -> String {
            if value is NSNull {
                throw CLIError(message: "TOML format does not support null values; use --format json for settings with null values")
            }
            if let bool = booleanValue(value) {
                return bool ? "true" : "false"
            }
            if let number = value as? NSNumber {
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

        private func booleanValue(_ value: Any) -> Bool? {
            if let number = value as? NSNumber {
                guard CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else {
                    return nil
                }
                return number.boolValue
            }
            return value as? Bool
        }

        private func escapeToml(_ value: String) -> String {
            var output = ""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0x08:
                    output.append("\\b")
                case 0x09:
                    output.append("\\t")
                case 0x0A:
                    output.append("\\n")
                case 0x0C:
                    output.append("\\f")
                case 0x0D:
                    output.append("\\r")
                case 0x22:
                    output.append("\\\"")
                case 0x5C:
                    output.append("\\\\")
                case 0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F:
                    output.append(String(format: "\\u%04X", scalar.value))
                default:
                    output.append(String(scalar))
                }
            }
            return output
        }

        private func parseToml(data: Data) throws -> [String: Any] {
            guard let source = String(data: data, encoding: .utf8) else {
                throw CLIError(message: "TOML import must be UTF-8")
            }
            var root: [String: Any] = [:]
            var tablePath: [String] = []
            var assignedPaths: Set<String> = []
            var lineNumber = 0
            for rawLine in source.components(separatedBy: .newlines) {
                lineNumber += 1
                let line = stripTomlComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                if line.hasPrefix("[") {
                    guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                        throw CLIError(message: "Unsupported TOML section header on line \(lineNumber)")
                    }
                    let header = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    tablePath = try parseTomlKeyPath(header, lineNumber: lineNumber)
                    continue
                }
                guard let equals = tomlAssignmentEquals(in: line) else {
                    throw CLIError(message: "Invalid TOML assignment on line \(lineNumber)")
                }
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                let literal = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let keyPath = tablePath + (try parseTomlKeyPath(key, lineNumber: lineNumber))
                let value = try parseTomlLiteral(String(literal), lineNumber: lineNumber)
                let pathKey = keyPath.joined(separator: "\u{1F}")
                if !assignedPaths.insert(pathKey).inserted {
                    throw CLIError(message: "Duplicate TOML key '\(keyPath.joined(separator: "."))' on line \(lineNumber)")
                }
                try setTomlValue(value, forComponents: keyPath, lineNumber: lineNumber, in: &root)
            }
            return root
        }

        private func parseTomlKeyPath(_ raw: String, lineNumber: Int) throws -> [String] {
            var components: [String] = []
            var index = raw.startIndex
            let invalid = CLIError(message: "Invalid TOML key path on line \(lineNumber)")

            func skipWhitespace() {
                while index < raw.endIndex, raw[index].isWhitespace {
                    index = raw.index(after: index)
                }
            }

            func parseQuotedKey() throws -> String {
                let quote = raw[index]
                let contentStart = raw.index(after: index)
                var contentEnd = contentStart
                var escaped = false
                while contentEnd < raw.endIndex {
                    let character = raw[contentEnd]
                    if escaped {
                        escaped = false
                        contentEnd = raw.index(after: contentEnd)
                        continue
                    }
                    if quote == "\"", character == "\\" {
                        escaped = true
                        contentEnd = raw.index(after: contentEnd)
                        continue
                    }
                    if character == quote {
                        let inner = String(raw[contentStart..<contentEnd])
                        index = raw.index(after: contentEnd)
                        return quote == "\"" ? try unescapeTomlString(inner, lineNumber: lineNumber) : inner
                    }
                    contentEnd = raw.index(after: contentEnd)
                }
                throw invalid
            }

            while true {
                skipWhitespace()
                guard index < raw.endIndex else {
                    throw invalid
                }

                let component: String
                if raw[index] == "\"" || raw[index] == "'" {
                    component = try parseQuotedKey()
                } else {
                    let start = index
                    while index < raw.endIndex, raw[index] != "." {
                        index = raw.index(after: index)
                    }
                    component = String(raw[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard isTomlBareKey(component) else {
                        throw invalid
                    }
                }

                guard !component.isEmpty else {
                    throw invalid
                }
                components.append(component)
                skipWhitespace()
                if index == raw.endIndex {
                    return components
                }
                guard raw[index] == "." else {
                    throw invalid
                }
                index = raw.index(after: index)
            }
        }

        private func tomlAssignmentEquals(in line: String) -> String.Index? {
            var activeQuote: Character?
            var escaped = false
            for index in line.indices {
                let character = line[index]
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" && activeQuote == "\"" {
                    escaped = true
                    continue
                }
                if character == "\"", activeQuote != "'" {
                    activeQuote = activeQuote == "\"" ? nil : "\""
                    continue
                }
                if character == "'", activeQuote != "\"" {
                    activeQuote = activeQuote == "'" ? nil : "'"
                    continue
                }
                if character == "=", activeQuote == nil {
                    return index
                }
            }
            return nil
        }

        private func stripTomlComment(_ rawLine: String) -> String {
            var activeQuote: Character?
            var escaped = false
            for index in rawLine.indices {
                let character = rawLine[index]
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" && activeQuote == "\"" {
                    escaped = true
                    continue
                }
                if character == "\"", activeQuote != "'" {
                    activeQuote = activeQuote == "\"" ? nil : "\""
                    continue
                }
                if character == "'", activeQuote != "\"" {
                    activeQuote = activeQuote == "'" ? nil : "'"
                    continue
                }
                if character == "#", activeQuote == nil {
                    return String(rawLine[..<index])
                }
            }
            return rawLine
        }

        private func parseTomlLiteral(_ raw: String, lineNumber: Int) throws -> Any {
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
                            message: "Unsupported TOML inline table literal on line \(lineNumber). Use dotted TOML keys or --format json."
                        )
                    }
                    throw CLIError(
                        message: "Invalid TOML array/object literal on line \(lineNumber). Use JSON-style arrays/objects or --format json."
                    )
                }
                return value
            }
            if raw.hasPrefix("\"\"\"") {
                throw CLIError(message: "Unsupported TOML multi-line basic string on line \(lineNumber)")
            }
            if raw.hasPrefix("\"") {
                guard raw.count >= 2, raw.hasSuffix("\"") else {
                    throw CLIError(message: "Invalid TOML basic string on line \(lineNumber)")
                }
                let inner = raw.dropFirst().dropLast()
                return try unescapeTomlString(String(inner), lineNumber: lineNumber)
            }
            if raw.hasPrefix("'") {
                guard !raw.hasPrefix("'''") else {
                    throw CLIError(message: "Unsupported TOML multi-line literal string on line \(lineNumber)")
                }
                guard raw.count >= 2, raw.hasSuffix("'") else {
                    throw CLIError(message: "Invalid TOML literal string on line \(lineNumber)")
                }
                let inner = raw.dropFirst().dropLast()
                guard !inner.contains("'") else {
                    throw CLIError(message: "Invalid TOML literal string on line \(lineNumber)")
                }
                return String(inner)
            }
            return raw
        }

        private func unescapeTomlString(_ raw: String, lineNumber: Int? = nil) throws -> String {
            var output = ""

            func hexValue(_ character: Character) -> UInt32? {
                guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
                    return nil
                }
                switch scalar.value {
                case 48...57:
                    return scalar.value - 48
                case 65...70:
                    return scalar.value - 65 + 10
                case 97...102:
                    return scalar.value - 97 + 10
                default:
                    return nil
                }
            }

            func appendUnicodeEscape(length: Int, after markerIndex: String.Index) throws -> String.Index {
                var value: UInt32 = 0
                var digitIndex = raw.index(after: markerIndex)
                for _ in 0..<length {
                    guard digitIndex < raw.endIndex, let digit = hexValue(raw[digitIndex]) else {
                        throw CLIError(message: "Invalid TOML unicode escape")
                    }
                    value = (value * 16) + digit
                    digitIndex = raw.index(after: digitIndex)
                }
                guard let scalar = UnicodeScalar(value) else {
                    throw CLIError(message: "Invalid TOML unicode scalar")
                }
                output.append(String(scalar))
                return digitIndex
            }

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
                case "b":
                    output.append("\u{08}")
                case "t":
                    output.append("\t")
                case "n":
                    output.append("\n")
                case "f":
                    output.append("\u{0C}")
                case "r":
                    output.append("\r")
                case "\"":
                    output.append("\"")
                case "\\":
                    output.append("\\")
                case "u":
                    index = try appendUnicodeEscape(length: 4, after: escapeIndex)
                    continue
                case "U":
                    index = try appendUnicodeEscape(length: 8, after: escapeIndex)
                    continue
                default:
                    throw CLIError(message: "Unsupported TOML string escape: \\\(raw[escapeIndex])")
                }
                index = raw.index(after: escapeIndex)
            }
            return output
        }
    }
}
