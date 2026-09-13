import Foundation

extension CmuxCodexConfigEditor {
    func tomlBasicStringContent(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                escaped += "\\b"
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0C:
                escaped += "\\f"
            case 0x0D:
                escaped += "\\r"
            case 0x22:
                escaped += "\\\""
            case 0x5C:
                escaped += "\\\\"
            case 0x00...0x1F, 0x7F...0x9F:
                if scalar.value <= 0xFFFF {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped += String(format: "\\U%08X", scalar.value)
                }
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return escaped
    }

    func tomlLines(from content: String) -> [String] {
        CmuxConfigLines().split(content)
    }

    func tomlContent(from lines: [String], lineEnding: CmuxConfigLines.LineEnding) -> String {
        CmuxConfigLines().joined(lines, lineEnding: lineEnding)
    }

    /// Removes legacy `codex_hooks` settings that cmux may have written.
    ///
    /// Root-scoped dotted settings and `[features]`-scoped settings are removed;
    /// the same key inside a user-owned table is preserved. The lines are rebuilt
    /// in one filtered pass, so a config with many legacy entries costs O(n).
    func removeLegacyCodexHooksSettings(from lines: inout [String]) {
        var isRoot = true
        var isFeaturesTable = false

        let retained = lines.filter { line in
            if tomlLineIsAnyTableHeader(line) {
                isRoot = false
                isFeaturesTable = tomlLineIsTable("features", line: line)
                return true
            }

            let removesRootSetting = isRoot && (
                tomlLineDefinesKey("codex_hooks", line: line)
                    || tomlLineDefinesDottedFeaturesKey("codex_hooks", line: line)
            )
            let removesFeaturesSetting = isFeaturesTable
                && tomlLineDefinesKey("codex_hooks", line: line)
            return !(removesRootSetting || removesFeaturesSetting)
        }

        lines = retained
    }

    func tomlLineDefinesKey(_ key: String, line: String) -> Bool {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        return line.range(
            of: #"^\s*"# + escapedKey + #"\s*="#,
            options: .regularExpression
        ) != nil
    }

    func tomlLineDefinesTrueKey(_ key: String, line: String) -> Bool {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        return line.range(
            of: #"^\s*"# + escapedKey + #"\s*=\s*true\s*(#.*)?$"#,
            options: .regularExpression
        ) != nil
    }

    func tomlLineDefinesDottedFeaturesKey(_ key: String, line: String) -> Bool {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        return line.range(
            of: #"^\s*features\s*\.\s*"# + escapedKey + #"\s*="#,
            options: .regularExpression
        ) != nil
    }

    func tomlLineDefinesDottedFeaturesTrueKey(_ key: String, line: String) -> Bool {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        return line.range(
            of: #"^\s*features\s*\.\s*"# + escapedKey + #"\s*=\s*true\s*(#.*)?$"#,
            options: .regularExpression
        ) != nil
    }

    func tomlLineDefinesAnyDottedFeaturesKey(_ line: String) -> Bool {
        line.range(
            of: #"^\s*features\s*\.\s*[^=\s]+\s*="#,
            options: .regularExpression
        ) != nil
    }

    /// One TOML key: bare, basic-quoted, or literal-quoted.
    private static let tomlKeyPattern =
        #"(?:[A-Za-z0-9_-]+|"(?:[^"\\\n]|\\.)*"|'[^'\n]*')"#

    /// Full single-bracket `[table]` or `[[array-of-tables]]` header.
    private static let tomlAnyTableHeaderPattern =
        #"^\s*(?:\[\s*"# + tomlKeyPattern + #"(?:\s*\.\s*"# + tomlKeyPattern
            + #")*\s*\]|\[\[\s*"# + tomlKeyPattern + #"(?:\s*\.\s*"# + tomlKeyPattern
            + #")*\s*\]\])\s*(#.*)?$"#

    private static let tomlTableHeaderRegex = try! NSRegularExpression(
        pattern: #"^\s*\[\s*("# + tomlKeyPattern + #"(?:\s*\.\s*"# + tomlKeyPattern
            + #")*)\s*\]\s*(#.*)?$"#
    )

    /// Whether `line` is the `[name]` table header, quoted or bare.
    ///
    /// - Parameter name: A plain dotted key path, e.g. `features`.
    func tomlLineIsTable(_ name: String, line: String) -> Bool {
        guard let keyPath = tomlTableKeyPath(line) else { return false }
        return keyPath == name.split(separator: ".").map(String.init)
    }

    /// Decoded TOML key path of a `[table]` header line, or `nil` for every other
    /// line (values, comments, array-of-tables headers, malformed or
    /// undecodable keys).
    ///
    /// Quoted components are decoded before comparison, so `[features]`,
    /// `["features"]`, and `['features']` all name the same table — which is what
    /// keeps the editor from appending a duplicate, invalid table header.
    func tomlTableKeyPath(_ line: String) -> [String]? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = Self.tomlTableHeaderRegex.firstMatch(in: line, range: range),
              let keyRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return tomlKeyPathComponents(String(line[keyRange]))
    }

    func tomlLineIsAnyTableHeader(_ line: String) -> Bool {
        line.range(of: Self.tomlAnyTableHeaderPattern, options: .regularExpression) != nil
    }

    /// Splits a validated `[table]` key path into decoded components, or `nil`
    /// when a quoted component contains an escape TOML does not define.
    private func tomlKeyPathComponents(_ keyPath: String) -> [String]? {
        var components: [String] = []
        var current = ""
        var index = keyPath.startIndex

        while index < keyPath.endIndex {
            let character = keyPath[index]
            switch character {
            case "\"", "'":
                let quote = character
                var literal = ""
                var cursor = keyPath.index(after: index)
                var closed = false
                while cursor < keyPath.endIndex {
                    let candidate = keyPath[cursor]
                    if quote == "\"", candidate == "\\" {
                        literal.append(candidate)
                        cursor = keyPath.index(after: cursor)
                        guard cursor < keyPath.endIndex else { return nil }
                        literal.append(keyPath[cursor])
                        cursor = keyPath.index(after: cursor)
                        continue
                    }
                    if candidate == quote {
                        closed = true
                        cursor = keyPath.index(after: cursor)
                        break
                    }
                    literal.append(candidate)
                    cursor = keyPath.index(after: cursor)
                }
                guard closed else { return nil }
                let decoded = quote == "\"" ? tomlDecodedBasicStringContent(literal) : literal
                guard let decoded else { return nil }
                current += decoded
                index = cursor
            case ".":
                components.append(current)
                current = ""
                index = keyPath.index(after: index)
            case " ", "\t":
                index = keyPath.index(after: index)
            default:
                current.append(character)
                index = keyPath.index(after: index)
            }
        }

        components.append(current)
        return components
    }

    /// Decodes a TOML basic-string body, or `nil` for an undefined escape.
    private func tomlDecodedBasicStringContent(_ literal: String) -> String? {
        var decoded = ""
        var index = literal.startIndex

        while index < literal.endIndex {
            guard literal[index] == "\\" else {
                decoded.append(literal[index])
                index = literal.index(after: index)
                continue
            }

            let escapeIndex = literal.index(after: index)
            guard escapeIndex < literal.endIndex else { return nil }
            switch literal[escapeIndex] {
            case "b": decoded.append("\u{08}")
            case "t": decoded.append("\t")
            case "n": decoded.append("\n")
            case "f": decoded.append("\u{0C}")
            case "r": decoded.append("\r")
            case "\"": decoded.append("\"")
            case "\\": decoded.append("\\")
            case "u", "U":
                let digitCount = literal[escapeIndex] == "u" ? 4 : 8
                let digitsStart = literal.index(after: escapeIndex)
                guard let digitsEnd = literal.index(
                    digitsStart,
                    offsetBy: digitCount,
                    limitedBy: literal.endIndex
                ),
                    let value = UInt32(literal[digitsStart..<digitsEnd], radix: 16),
                    let scalar = Unicode.Scalar(value)
                else { return nil }
                decoded.unicodeScalars.append(scalar)
                index = digitsEnd
                continue
            default: return nil
            }

            index = literal.index(after: escapeIndex)
        }

        return decoded
    }

    func tomlTableEndIndex(in lines: [String], after tableStart: Int) -> Int {
        var index = tableStart + 1
        while index < lines.count {
            if tomlLineIsAnyTableHeader(lines[index]) {
                return index
            }
            index += 1
        }
        return lines.count
    }

    func codexHookTrustTableEscapedKey(from line: String) -> String? {
        let pattern = #"^\s*\[\s*hooks\s*\.\s*state\s*\.\s*"((?:[^"\\\n]|\\.)*)"\s*\]\s*(#.*)?$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let keyRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[keyRange])
    }

    func tomlLineIsCodexHookTrustBlockTableBoundary(_ line: String) -> Bool {
        codexHookTrustTableEscapedKey(from: line) != nil || tomlLineIsAnyTableHeader(line)
    }

    func tomlLineIsCodexHooksFeatureBegin(_ line: String) -> Bool {
        line == Self.cmuxCodexHooksFeatureBegin || line == Self.legacyCmuxCodexHooksFeatureBegin
    }

    func tomlLineIsCodexHooksFeatureEnd(_ line: String) -> Bool {
        line == Self.cmuxCodexHooksFeatureEnd || line == Self.legacyCmuxCodexHooksFeatureEnd
    }

    func tomlCodexHooksFeaturePreviousLine(from line: String) -> String? {
        if line.hasPrefix(Self.cmuxCodexHooksFeaturePreviousLinePrefix) {
            return String(line.dropFirst(Self.cmuxCodexHooksFeaturePreviousLinePrefix.count))
        }
        if line.hasPrefix(Self.legacyCmuxCodexHooksFeaturePreviousLinePrefix) {
            return String(line.dropFirst(Self.legacyCmuxCodexHooksFeaturePreviousLinePrefix.count))
        }
        return nil
    }

    func tomlLineIsCodexHooksFeatureSetting(_ line: String) -> Bool {
        tomlLineDefinesTrueKey("hooks", line: line)
            || tomlLineDefinesDottedFeaturesTrueKey("hooks", line: line)
    }

    func removeEmptyFeaturesTable(from lines: inout [String]) {
        guard let featuresStart = lines.firstIndex(where: { tomlLineIsTable("features", line: $0) }) else {
            return
        }
        let featuresEnd = tomlTableEndIndex(in: lines, after: featuresStart)
        let bodyRange = featuresStart + 1..<featuresEnd
        let hasContent = bodyRange.contains { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        if !hasContent {
            lines.removeSubrange(featuresStart..<featuresEnd)
            if featuresStart == lines.count, featuresStart > 0,
               lines[featuresStart - 1].trimmingCharacters(in: .whitespaces).isEmpty
            {
                lines.remove(at: featuresStart - 1)
            } else if featuresStart > 0, featuresStart < lines.count,
                      lines[featuresStart - 1].trimmingCharacters(in: .whitespaces).isEmpty,
                      lines[featuresStart].trimmingCharacters(in: .whitespaces).isEmpty
            {
                lines.remove(at: featuresStart)
            }
        }
    }
}
