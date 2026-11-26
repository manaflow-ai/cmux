import Foundation

public enum RovoDevHookConfig {
    public struct Event: Equatable {
        public var name: String
        public var command: String

        public init(name: String, command: String) {
            self.name = name
            self.command = command
        }
    }

    private static let beginMarker = "# cmux hooks rovodev begin"
    private static let endMarker = "# cmux hooks rovodev end"

    public static func installing(events: [Event], in existing: String) -> String {
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

    public static func uninstalling(from existing: String) -> String {
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
        var result = lines
        var index = 0
        while index < result.count {
            guard result[index].trimmingCharacters(in: .whitespaces) == beginMarker else {
                index += 1
                continue
            }

            guard let endIndex = result[(index + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == endMarker
            }) else {
                index += 1
                continue
            }

            let removalStart = result.indices.contains(index - 1)
                && result[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? index - 1
                : index
            result.removeSubrange(removalStart...endIndex)
            index = removalStart
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
        let eventsIndent = leadingWhitespace(lines[eventHooksIndex]) + "  "
        for index in (eventHooksIndex + 1)..<lines.count {
            let line = lines[index]
            if line.range(of: #"^\S"#, options: .regularExpression) != nil {
                return nil
            }
            guard line.hasPrefix(eventsIndent) else { continue }
            let suffix = String(line.dropFirst(eventsIndent.count))
            if suffix.range(of: #"^events:\s*(#.*)?$"#, options: .regularExpression) != nil {
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
