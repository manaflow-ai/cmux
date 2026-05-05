import Foundation

enum RovoDevHookConfig {
    struct Event: Equatable {
        var name: String
        var command: String
    }

    private static let beginMarker = "# cmux hooks rovodev begin"
    private static let endMarker = "# cmux hooks rovodev end"

    static func installing(events: [Event], in existing: String) -> String {
        var lines = normalizedLines(existing)
        lines = removingMarkedBlock(lines)

        if let eventsIndex = eventsLineIndex(in: lines) {
            let eventIndent = leadingWhitespace(lines[eventsIndex]) + "  "
            let block = eventHooksBlock(events: events, itemIndent: eventIndent)
            lines.insert(contentsOf: block, at: eventsIndex + 1)
        } else if let eventHooksIndex = eventHooksLineIndex(in: lines) {
            let childIndent = leadingWhitespace(lines[eventHooksIndex]) + "  "
            var block = [
                "\(childIndent)\(beginMarker)",
                "\(childIndent)events:"
            ]
            block.append(contentsOf: eventHooksBlock(events: events, itemIndent: childIndent + "  ", includeMarkers: false))
            block.append("\(childIndent)\(endMarker)")
            lines.insert(contentsOf: block, at: eventHooksIndex + 1)
        } else {
            if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                lines.append("")
            }
            lines.append(beginMarker)
            lines.append("eventHooks:")
            lines.append("  events:")
            lines.append(contentsOf: eventHooksBlock(events: events, itemIndent: "    ", includeMarkers: false))
            lines.append(endMarker)
        }

        return serialized(lines)
    }

    static func uninstalling(from existing: String) -> String {
        serialized(removingMarkedBlock(normalizedLines(existing)))
    }

    private static func normalizedLines(_ content: String) -> [String] {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func serialized(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func eventHooksBlock(
        events: [Event],
        itemIndent: String,
        includeMarkers: Bool = true
    ) -> [String] {
        var lines: [String] = []
        if includeMarkers {
            lines.append("\(itemIndent)\(beginMarker)")
        }
        for event in events {
            lines.append("\(itemIndent)- name: \(event.name)")
            lines.append("\(itemIndent)  commands:")
            lines.append("\(itemIndent)    - command: \(yamlDoubleQuoted(event.command))")
        }
        if includeMarkers {
            lines.append("\(itemIndent)\(endMarker)")
        }
        return lines
    }

    private static func removingMarkedBlock(_ lines: [String]) -> [String] {
        var result: [String] = []
        var skipping = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == beginMarker {
                if result.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    result.removeLast()
                }
                skipping = true
                continue
            }
            if skipping {
                if line.trimmingCharacters(in: .whitespaces) == endMarker {
                    skipping = false
                }
                continue
            }
            result.append(line)
        }
        return result
    }

    private static func eventHooksLineIndex(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            line.range(of: #"^eventHooks:\s*(#.*)?$"#, options: .regularExpression) != nil
        }
    }

    private static func eventsLineIndex(in lines: [String]) -> Int? {
        guard let eventHooksIndex = eventHooksLineIndex(in: lines) else { return nil }
        for index in (eventHooksIndex + 1)..<lines.count {
            let line = lines[index]
            if line.range(of: #"^\S"#, options: .regularExpression) != nil {
                return nil
            }
            if line.range(of: #"^\s+events:\s*(#.*)?$"#, options: .regularExpression) != nil {
                return index
            }
        }
        return nil
    }

    private static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func yamlDoubleQuoted(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
