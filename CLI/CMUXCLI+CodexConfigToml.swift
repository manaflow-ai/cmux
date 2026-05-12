import Foundation

extension CMUXCLI {
    private static let cmuxCodexHooksFeatureBegin = "# cmux hooks codex feature begin"
    private static let cmuxCodexHooksFeatureEnd = "# cmux hooks codex feature end"

    static func codexConfigTomlInstallingHooksFeature(in existingContent: String) -> String {
        var lines = tomlLines(from: existingContent)
        removeCmuxCodexHooksFeatureBlock(from: &lines)
        lines.removeAll { tomlLineDefinesKey("codex_hooks", line: $0) }

        let insertedLines = [
            cmuxCodexHooksFeatureBegin,
            "hooks = true",
            cmuxCodexHooksFeatureEnd,
        ]

        if let featuresStart = lines.firstIndex(where: { tomlLineIsTable("features", line: $0) }) {
            let featuresEnd = tomlTableEndIndex(in: lines, after: featuresStart)
            if featuresStart + 1 < featuresEnd,
               let hooksIndex = (featuresStart + 1..<featuresEnd)
                .first(where: { tomlLineDefinesKey("hooks", line: lines[$0]) })
            {
                lines[hooksIndex] = "hooks = true"
            } else {
                lines.insert(contentsOf: insertedLines, at: featuresStart + 1)
            }
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("[features]")
            lines.append(contentsOf: insertedLines)
        }

        return tomlContent(from: lines)
    }

    static func codexConfigTomlUninstallingHooksFeature(from existingContent: String) -> String {
        var lines = tomlLines(from: existingContent)
        removeCmuxCodexHooksFeatureBlock(from: &lines)
        lines.removeAll { tomlLineDefinesKey("codex_hooks", line: $0) }
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

    private static func tomlLineIsTable(_ name: String, line: String) -> Bool {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        return line.range(
            of: #"^\s*\[\s*"# + escapedName + #"\s*\]\s*(#.*)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func tomlLineIsAnyTableHeader(_ line: String) -> Bool {
        line.range(
            of: #"^\s*\[+[^]]+\]+\s*(#.*)?$"#,
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
            guard lines[index].trimmingCharacters(in: .whitespaces) == cmuxCodexHooksFeatureBegin else {
                index += 1
                continue
            }

            if let endIndex = lines[index...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == cmuxCodexHooksFeatureEnd
            }) {
                lines.removeSubrange(index...endIndex)
            } else {
                lines.remove(at: index)
            }
        }
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
