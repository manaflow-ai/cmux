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

    private static let tomlMultilineContentPrefix = "\u{001F}"

    func tomlLines(from content: String) -> [String] {
        var delimiter: String?
        return CmuxConfigLines().split(content).map { line in
            let result = delimiter.map { _ in Self.tomlMultilineContentPrefix + line } ?? line
            delimiter = tomlMultilineStringDelimiter(after: line, startingIn: delimiter)
            return result
        }
    }

    func tomlContent(from lines: [String], lineEnding: CmuxConfigLines.LineEnding) -> String {
        let unmaskedLines = lines.map { line in
            line.hasPrefix(Self.tomlMultilineContentPrefix)
                ? String(line.dropFirst(Self.tomlMultilineContentPrefix.count))
                : line
        }
        return CmuxConfigLines().joined(unmaskedLines, lineEnding: lineEnding)
    }

    private func tomlMultilineStringDelimiter(after line: String, startingIn delimiter: String?) -> String? {
        var index = line.startIndex
        var activeDelimiter = delimiter
        let contentEnd = tomlCommentStart(in: line) ?? line.endIndex

        while index < contentEnd {
            if let currentDelimiter = activeDelimiter {
                guard let end = line.range(of: currentDelimiter, range: index..<contentEnd) else {
                    return currentDelimiter
                }
                if currentDelimiter == "\"\"\"" && isEscaped(in: line, at: end.lowerBound) {
                    index = end.upperBound
                    continue
                }
                activeDelimiter = nil
                index = end.upperBound
                continue
            }

            let basic = line.range(of: "\"\"\"", range: index..<contentEnd)
            let literal = line.range(of: "'''", range: index..<contentEnd)
            let next: (String, Range<String.Index>)?
            switch (basic, literal) {
            case let (basic?, literal?):
                next = basic.lowerBound < literal.lowerBound ? ("\"\"\"", basic) : ("'''", literal)
            case let (basic?, nil):
                next = ("\"\"\"", basic)
            case let (nil, literal?):
                next = ("'''", literal)
            case (nil, nil):
                return nil
            }

            guard let next else { return nil }
            if next.0 == "\"\"\"" && isEscaped(in: line, at: next.1.lowerBound) {
                index = next.1.upperBound
            } else {
                activeDelimiter = next.0
                index = next.1.upperBound
            }
        }

        return activeDelimiter
    }

    private func tomlCommentStart(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let currentQuote = quote {
                if currentQuote == "\"" {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == currentQuote {
                        quote = nil
                    }
                } else if character == currentQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }

    private func isEscaped(in line: String, at index: String.Index) -> Bool {
        var backslashes = 0
        var cursor = index
        while cursor > line.startIndex {
            cursor = line.index(before: cursor)
            guard line[cursor] == "\\" else { break }
            backslashes += 1
        }
        return backslashes % 2 == 1
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

    func tomlLineIsTable(_ name: String, line: String) -> Bool {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        return line.range(
            of: #"^\s*\[\s*"# + escapedName + #"\s*\]\s*(#.*)?$"#,
            options: .regularExpression
        ) != nil
    }

    func tomlLineIsAnyTableHeader(_ line: String) -> Bool {
        let tomlKey = #"(?:[A-Za-z0-9_-]+|"[^"\n]*"|'[^'\n]*')"#
        let tomlKeyPath = tomlKey + #"(?:\s*\.\s*"# + tomlKey + ")*"
        let pattern = #"^\s*(?:\[\s*"# + tomlKeyPath + #"\s*\]|\[\[\s*"# + tomlKeyPath
            + #"\s*\]\])\s*(#.*)?$"#
        return line.range(of: pattern, options: .regularExpression) != nil
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
