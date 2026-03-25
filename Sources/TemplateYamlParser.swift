import Foundation

/// Parses workspace template YAML files into `WorkspaceTemplate` structures.
/// Supports both the new `root:` tree format and legacy `tabs:` format.
enum TemplateYamlParser {

    /// Parse a template YAML string into a WorkspaceTemplate.
    static func parse(_ content: String) throws -> WorkspaceTemplate {
        let lines = content.components(separatedBy: .newlines)
        let hasRoot = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("root:") }
        if hasRoot {
            return try parseNewFormat(lines)
        }
        return try parseLegacyFormat(lines)
    }

    // MARK: - New Format

    private static func parseNewFormat(_ lines: [String]) throws -> WorkspaceTemplate {
        let root = try parseNodeBlock(lines: lines, startKey: "root:")
        return WorkspaceTemplate(root: root)
    }

    private static func parseNodeBlock(lines: [String], startKey: String) throws -> TemplateNode {
        guard let rootLineIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == startKey ||
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(startKey)
        }) else {
            throw TemplateParseError.missingRoot
        }

        let rootIndent = indentLevel(of: lines[rootLineIdx])
        let childIndent = rootIndent + 2

        var title = "Terminal"
        var color: String?
        var command: String?
        var children: [TemplateNode] = []

        var idx = rootLineIdx + 1
        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { idx += 1; continue }

            let lineIndent = indentLevel(of: line)
            if lineIndent <= rootIndent { break }

            if trimmed.hasPrefix("title:") {
                title = extractYamlValue(trimmed, key: "title:") ?? "Terminal"
            } else if trimmed.hasPrefix("color:") {
                color = extractYamlValue(trimmed, key: "color:")
            } else if trimmed.hasPrefix("command:") {
                let inlineValue = extractYamlValue(trimmed, key: "command:")
                if inlineValue == "|" || inlineValue == nil {
                    let (block, nextIdx) = readBlockScalar(lines: lines, from: idx + 1, baseIndent: lineIndent + 2)
                    command = block
                    idx = nextIdx
                    continue
                } else {
                    command = inlineValue
                }
            } else if trimmed == "children:" {
                let (parsed, nextIdx) = parseChildrenList(
                    lines: lines, from: idx + 1, listIndent: childIndent + 2
                )
                children = parsed
                idx = nextIdx
                continue
            }
            idx += 1
        }

        return TemplateNode(title: title, color: color, command: command, children: children)
    }

    private static func parseChildrenList(
        lines: [String], from startIdx: Int, listIndent: Int
    ) -> ([TemplateNode], Int) {
        var children: [TemplateNode] = []
        var idx = startIdx

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { idx += 1; continue }

            let lineIndent = indentLevel(of: line)
            if lineIndent < listIndent { break }

            if trimmed.hasPrefix("- title:") {
                let (node, nextIdx) = parseChildNode(lines: lines, from: idx, itemIndent: lineIndent)
                children.append(node)
                idx = nextIdx
                continue
            }
            idx += 1
        }
        return (children, idx)
    }

    private static func parseChildNode(
        lines: [String], from startIdx: Int, itemIndent: Int
    ) -> (TemplateNode, Int) {
        let firstLine = lines[startIdx].trimmingCharacters(in: .whitespaces)
        var title = extractYamlValue(firstLine, key: "- title:") ?? "Workspace"
        var color: String?
        var command: String?
        var children: [TemplateNode] = []

        let propIndent = itemIndent + 2
        var idx = startIdx + 1

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { idx += 1; continue }

            let lineIndent = indentLevel(of: line)
            if lineIndent < propIndent { break }
            if lineIndent == itemIndent && trimmed.hasPrefix("- ") { break }

            if trimmed.hasPrefix("title:") {
                title = extractYamlValue(trimmed, key: "title:") ?? title
            } else if trimmed.hasPrefix("color:") {
                color = extractYamlValue(trimmed, key: "color:")
            } else if trimmed.hasPrefix("command:") {
                let inlineValue = extractYamlValue(trimmed, key: "command:")
                if inlineValue == "|" || inlineValue == nil {
                    let (block, nextIdx) = readBlockScalar(lines: lines, from: idx + 1, baseIndent: lineIndent + 2)
                    command = block
                    idx = nextIdx
                    continue
                } else {
                    command = inlineValue
                }
            } else if trimmed == "children:" {
                let (parsed, nextIdx) = parseChildrenList(
                    lines: lines, from: idx + 1, listIndent: lineIndent + 2
                )
                children = parsed
                idx = nextIdx
                continue
            }
            idx += 1
        }

        return (TemplateNode(title: title, color: color, command: command, children: children), idx)
    }

    // MARK: - Block Scalar

    private static func readBlockScalar(
        lines: [String], from startIdx: Int, baseIndent: Int
    ) -> (String, Int) {
        var result: [String] = []
        var idx = startIdx

        while idx < lines.count {
            let line = lines[idx]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                var nextNonEmpty = idx + 1
                while nextNonEmpty < lines.count &&
                      lines[nextNonEmpty].trimmingCharacters(in: .whitespaces).isEmpty {
                    nextNonEmpty += 1
                }
                if nextNonEmpty < lines.count && indentLevel(of: lines[nextNonEmpty]) >= baseIndent {
                    result.append("")
                    idx += 1
                    continue
                }
                break
            }
            let lineIndent = indentLevel(of: line)
            if lineIndent < baseIndent { break }
            let content = String(line.dropFirst(min(baseIndent, line.count)))
            result.append(content)
            idx += 1
        }

        return (result.joined(separator: "\n").trimmingCharacters(in: .newlines), idx)
    }

    // MARK: - Legacy Format

    private static func parseLegacyFormat(_ lines: [String]) throws -> WorkspaceTemplate {
        var tabs: [TemplateTabDefinition] = []
        var inTabs = false
        var currentTitle: String?
        var currentScript: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed == "tabs:" {
                inTabs = true
                continue
            }
            guard inTabs else { continue }

            if trimmed.hasPrefix("- title:") {
                if let title = currentTitle {
                    tabs.append(TemplateTabDefinition(title: title, startupScript: currentScript))
                }
                currentTitle = extractYamlValue(trimmed, key: "- title:")
                currentScript = nil
            } else if trimmed.hasPrefix("startupScript:") {
                currentScript = extractYamlValue(trimmed, key: "startupScript:")
            }
        }
        if let title = currentTitle {
            tabs.append(TemplateTabDefinition(title: title, startupScript: currentScript))
        }

        let children = tabs.map { tab in
            TemplateNode(title: tab.title, color: nil, command: nil, children: [])
        }
        return WorkspaceTemplate(root: TemplateNode(
            title: "Terminal", color: nil, command: nil, children: children
        ))
    }

    // MARK: - Serialization

    static func serialize(_ template: WorkspaceTemplate) -> String {
        var lines: [String] = []
        lines.append("root:")
        serializeNode(template.root, indent: 2, lines: &lines, isList: false)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func serializeNode(
        _ node: TemplateNode, indent: Int, lines: inout [String], isList: Bool
    ) {
        let pad = String(repeating: " ", count: indent)
        let prefix = isList ? "- " : ""
        lines.append("\(pad)\(prefix)title: \(node.title)")
        let propPad = isList ? pad + "  " : pad
        if let color = node.color {
            lines.append("\(propPad)color: \"\(color)\"")
        }
        if let command = node.command {
            if command.contains("\n") {
                lines.append("\(propPad)command: |")
                for cmdLine in command.components(separatedBy: .newlines) {
                    lines.append("\(propPad)  \(cmdLine)")
                }
            } else {
                lines.append("\(propPad)command: \(command)")
            }
        }
        if !node.children.isEmpty {
            lines.append("\(propPad)children:")
            for child in node.children {
                serializeNode(child, indent: indent + (isList ? 4 : 2), lines: &lines, isList: true)
            }
        }
    }

    // MARK: - Helpers

    static func indentLevel(of line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else { break }
        }
        return count
    }

    static func extractYamlValue(_ line: String, key: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}

enum TemplateParseError: Error {
    case missingRoot
}
