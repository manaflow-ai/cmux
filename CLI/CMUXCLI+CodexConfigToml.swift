import Foundation

extension CMUXCLI {
    private static let cmuxCodexHooksFeatureBegin =
        "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df begin"
    private static let cmuxCodexHooksFeatureEnd =
        "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df end"
    private static let cmuxCodexHooksFeaturePreviousLinePrefix =
        "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df previous line: "
    private static let legacyCmuxCodexHooksFeatureBegin = "# cmux hooks codex feature begin"
    private static let legacyCmuxCodexHooksFeatureEnd = "# cmux hooks codex feature end"
    private static let legacyCmuxCodexHooksFeaturePreviousLinePrefix = "# cmux hooks codex feature previous line: "

    static func codexConfigTomlInstallingHooksFeature(in existingContent: String) -> String {
        var lines = tomlLines(from: existingContent)
        removeCmuxCodexHooksFeatureBlock(from: &lines)
        lines.removeAll { tomlLineDefinesKey("codex_hooks", line: $0) }
        lines.removeAll { tomlLineDefinesDottedFeaturesKey("codex_hooks", line: $0) }

        let insertedLines = [
            cmuxCodexHooksFeatureBegin,
            "hooks = true",
            cmuxCodexHooksFeatureEnd,
        ]
        let insertedDottedLines = [
            cmuxCodexHooksFeatureBegin,
            "features.hooks = true",
            cmuxCodexHooksFeatureEnd,
        ]

        if let featuresStart = lines.firstIndex(where: { tomlLineIsTable("features", line: $0) }) {
            let featuresEnd = tomlTableEndIndex(in: lines, after: featuresStart)
            if featuresStart + 1 < featuresEnd,
               let hooksIndex = (featuresStart + 1..<featuresEnd)
                .first(where: { tomlLineDefinesKey("hooks", line: lines[$0]) })
            {
                if !tomlLineDefinesTrueKey("hooks", line: lines[hooksIndex]) {
                    let previousLine = lines[hooksIndex]
                    lines.replaceSubrange(
                        hooksIndex...hooksIndex,
                        with: codexHooksFeatureLines(settingLine: "hooks = true", previousLine: previousLine)
                    )
                }
            } else {
                lines.insert(contentsOf: insertedLines, at: featuresStart + 1)
            }
        } else if let dottedHooksIndex = lines.firstIndex(where: { tomlLineDefinesDottedFeaturesKey("hooks", line: $0) }) {
            if !tomlLineDefinesDottedFeaturesTrueKey("hooks", line: lines[dottedHooksIndex]) {
                let previousLine = lines[dottedHooksIndex]
                lines.replaceSubrange(
                    dottedHooksIndex...dottedHooksIndex,
                    with: codexHooksFeatureLines(settingLine: "features.hooks = true", previousLine: previousLine)
                )
            }
        } else if let firstDottedFeaturesIndex = lines.firstIndex(where: { tomlLineDefinesAnyDottedFeaturesKey($0) }) {
            lines.insert(contentsOf: insertedDottedLines, at: firstDottedFeaturesIndex)
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("[features]")
            lines.append(contentsOf: insertedLines)
        }

        return tomlContent(from: lines)
    }

    private static func codexHooksFeatureLines(settingLine: String, previousLine: String? = nil) -> [String] {
        var lines = [cmuxCodexHooksFeatureBegin]
        if let previousLine {
            lines.append(cmuxCodexHooksFeaturePreviousLinePrefix + previousLine)
        }
        lines.append(settingLine)
        lines.append(cmuxCodexHooksFeatureEnd)
        return lines
    }

    static func codexConfigTomlUninstallingHooksFeature(from existingContent: String) -> String {
        var lines = tomlLines(from: existingContent)
        removeCmuxCodexHooksFeatureBlock(from: &lines)
        lines.removeAll { tomlLineDefinesKey("codex_hooks", line: $0) }
        lines.removeAll { tomlLineDefinesDottedFeaturesKey("codex_hooks", line: $0) }
        removeEmptyFeaturesTable(from: &lines)
        return tomlContent(from: lines)
    }

    private static func tomlLines(from content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func tomlContent(from lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func tomlLineDefinesKey(_ key: String, line: String) -> Bool {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        return line.range(
            of: #"^\s*"# + escapedKey + #"\s*="#,
            options: .regularExpression
        ) != nil
    }

    private static func tomlLineDefinesTrueKey(_ key: String, line: String) -> Bool {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        return line.range(
            of: #"^\s*"# + escapedKey + #"\s*=\s*true\s*(#.*)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func tomlLineDefinesDottedFeaturesKey(_ key: String, line: String) -> Bool {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        return line.range(
            of: #"^\s*features\s*\.\s*"# + escapedKey + #"\s*="#,
            options: .regularExpression
        ) != nil
    }

    private static func tomlLineDefinesDottedFeaturesTrueKey(_ key: String, line: String) -> Bool {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        return line.range(
            of: #"^\s*features\s*\.\s*"# + escapedKey + #"\s*=\s*true\s*(#.*)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func tomlLineDefinesAnyDottedFeaturesKey(_ line: String) -> Bool {
        line.range(
            of: #"^\s*features\s*\.\s*[^=\s]+\s*="#,
            options: .regularExpression
        ) != nil
    }

    private static func tomlLineIsTable(_ name: String, line: String) -> Bool {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        return line.range(
            of: #"^\s*\[\s*"# + escapedName + #"\s*\]\s*(#.*)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func tomlLineIsAnyTableHeader(_ line: String) -> Bool {
        let tomlKey = "(?:[A-Za-z0-9_-]+|\"[^\"\\n]*\"|'[^'\\n]*')"
        let tomlKeyPath = tomlKey + "(?:\\s*\\.\\s*" + tomlKey + ")*"
        let pattern = "^\\s*(?:\\[\\s*" + tomlKeyPath + "\\s*\\]|\\[\\[\\s*" + tomlKeyPath
            + "\\s*\\]\\])\\s*(#.*)?$"
        return line.range(
            of: pattern,
            options: .regularExpression
        ) != nil
    }

    private static func tomlTableEndIndex(in lines: [String], after tableStart: Int) -> Int {
        var index = tableStart + 1
        while index < lines.count {
            if tomlLineIsAnyTableHeader(lines[index]) {
                return index
            }
            index += 1
        }
        return lines.count
    }

    private static func removeCmuxCodexHooksFeatureBlock(from lines: inout [String]) {
        var index = 0
        while index < lines.count {
            guard tomlLineIsCodexHooksFeatureBegin(lines[index]) else {
                index += 1
                continue
            }

            if let endIndex = lines[index...].firstIndex(where: {
                tomlLineIsCodexHooksFeatureEnd($0)
            }) {
                let previousLines = lines[index...endIndex].compactMap { line -> String? in
                    tomlCodexHooksFeaturePreviousLine(from: line)
                }
                lines.replaceSubrange(index...endIndex, with: previousLines)
            } else {
                lines.remove(at: index)
            }
        }
    }

    private static func tomlLineIsCodexHooksFeatureBegin(_ line: String) -> Bool {
        line == cmuxCodexHooksFeatureBegin || line == legacyCmuxCodexHooksFeatureBegin
    }

    private static func tomlLineIsCodexHooksFeatureEnd(_ line: String) -> Bool {
        line == cmuxCodexHooksFeatureEnd || line == legacyCmuxCodexHooksFeatureEnd
    }

    private static func tomlCodexHooksFeaturePreviousLine(from line: String) -> String? {
        if line.hasPrefix(cmuxCodexHooksFeaturePreviousLinePrefix) {
            return String(line.dropFirst(cmuxCodexHooksFeaturePreviousLinePrefix.count))
        }
        if line.hasPrefix(legacyCmuxCodexHooksFeaturePreviousLinePrefix) {
            return String(line.dropFirst(legacyCmuxCodexHooksFeaturePreviousLinePrefix.count))
        }
        return nil
    }

    private static func removeEmptyFeaturesTable(from lines: inout [String]) {
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
        }
    }
}
