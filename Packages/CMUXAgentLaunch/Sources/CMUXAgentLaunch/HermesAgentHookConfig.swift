import Foundation

public enum HermesAgentHookConfig {
    public struct Event: Equatable, Sendable {
        public var name: String
        public var command: String
        public var timeout: Int
        public var matcher: String?

        public init(name: String, command: String, timeout: Int = 5, matcher: String? = nil) {
            self.name = name
            self.command = command
            self.timeout = timeout
            self.matcher = matcher
        }
    }

    private static let beginMarker = "# cmux hooks hermes-agent begin"
    private static let endMarker = "# cmux hooks hermes-agent end"

    public static func installing(events: [Event], in existing: String) -> String {
        guard !events.isEmpty else {
            return uninstalling(from: existing)
        }

        var lines = normalizedLines(existing)
        lines = removingMarkedBlocks(lines)

        if let hooksIndex = hooksLineIndex(in: lines) {
            if inlineEmptyHooksLine(lines[hooksIndex]) {
                lines[hooksIndex] = "\(leadingWhitespace(lines[hooksIndex]))hooks:"
            }
            let childIndent = leadingWhitespace(lines[hooksIndex]) + "  "
            let existingEvents = directEventLineIndexes(in: lines, hooksIndex: hooksIndex)
            var missingEvents: [Event] = []

            for event in events {
                guard let eventIndex = existingEvents[event.name] else {
                    missingEvents.append(event)
                    continue
                }
                let entryIndent = leadingWhitespace(lines[eventIndex]) + "  "
                let block = hookListBlock(events: [event], itemIndent: entryIndent)
                lines.insert(contentsOf: block, at: eventIndex + 1)
            }

            if !missingEvents.isEmpty {
                let block = eventSectionsBlock(events: missingEvents, childIndent: childIndent)
                lines.insert(contentsOf: block, at: hooksIndex + 1)
            }
        } else {
            if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                lines.append("")
            }
            lines.append(beginMarker)
            lines.append("hooks:")
            lines.append(contentsOf: eventSectionsBlock(events: events, childIndent: "  ", includeMarkers: false))
            lines.append(endMarker)
        }

        return serialized(lines)
    }

    public static func uninstalling(from existing: String) -> String {
        serialized(removingMarkedBlocks(normalizedLines(existing)))
    }

    private static func normalizedLines(_ content: String) -> [String] {
        var lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func serialized(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func eventSectionsBlock(events: [Event], childIndent: String, includeMarkers: Bool = true) -> [String] {
        var lines: [String] = []
        if includeMarkers {
            lines.append("\(childIndent)\(beginMarker)")
        }
        for event in events {
            lines.append("\(childIndent)\(event.name):")
            lines.append(contentsOf: hookEntries(events: [event], itemIndent: childIndent + "  "))
        }
        if includeMarkers {
            lines.append("\(childIndent)\(endMarker)")
        }
        return lines
    }

    private static func hookListBlock(events: [Event], itemIndent: String) -> [String] {
        var lines = ["\(itemIndent)\(beginMarker)"]
        lines.append(contentsOf: hookEntries(events: events, itemIndent: itemIndent))
        lines.append("\(itemIndent)\(endMarker)")
        return lines
    }

    private static func hookEntries(events: [Event], itemIndent: String) -> [String] {
        var lines: [String] = []
        for event in events {
            lines.append("\(itemIndent)- command: \(yamlDoubleQuoted(event.command))")
            if let matcher = event.matcher?.trimmingCharacters(in: .whitespacesAndNewlines), !matcher.isEmpty {
                lines.append("\(itemIndent)  matcher: \(yamlDoubleQuoted(matcher))")
            }
            lines.append("\(itemIndent)  timeout: \(event.timeout)")
        }
        return lines
    }

    private static func removingMarkedBlocks(_ lines: [String]) -> [String] {
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

    private static func hooksLineIndex(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            leadingWhitespace(line).isEmpty
                && line.range(of: #"^hooks:\s*(\{\}\s*)?(#.*)?$"#, options: .regularExpression) != nil
        }
    }

    private static func inlineEmptyHooksLine(_ line: String) -> Bool {
        line.range(of: #"^hooks:\s*\{\}\s*(#.*)?$"#, options: .regularExpression) != nil
    }

    private static func directEventLineIndexes(in lines: [String], hooksIndex: Int) -> [String: Int] {
        let hooksIndent = leadingWhitespace(lines[hooksIndex])
        let childIndent = hooksIndent + "  "
        var indexes: [String: Int] = [:]

        var index = hooksIndex + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            guard line.hasPrefix(childIndent) else {
                break
            }
            guard leadingWhitespace(line) == childIndent,
                  let colon = trimmed.firstIndex(of: ":") else {
                index += 1
                continue
            }
            let name = String(trimmed[..<colon])
            let suffix = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if suffix.isEmpty || suffix.hasPrefix("#") {
                indexes[name] = index
            }
            index += 1
        }
        return indexes
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

public enum HermesAgentHookAllowlist {
    public static func installing(events: [HermesAgentHookConfig.Event], in existing: Data?, approvedAt: Date = Date()) throws -> Data {
        var object = try decode(existing)
        let approvals = object["approvals"] as? [[String: Any]] ?? []
        var keyed: [String: [String: Any]] = [:]
        for approval in approvals {
            guard let event = approval["event"] as? String,
                  let command = approval["command"] as? String else {
                continue
            }
            keyed[key(event: event, command: command)] = approval
        }

        let iso = ISO8601DateFormatter().string(from: approvedAt)
        for event in events {
            keyed[key(event: event.name, command: event.command)] = [
                "event": event.name,
                "command": event.command,
                "approved_at": iso,
            ]
        }
        object["approvals"] = keyed.values.sorted {
            (($0["event"] as? String) ?? "", ($0["command"] as? String) ?? "")
                < ((($1["event"] as? String) ?? ""), (($1["command"] as? String) ?? ""))
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    public static func uninstalling(events: [HermesAgentHookConfig.Event], from existing: Data?) throws -> Data {
        var object = try decode(existing)
        let ownedKeys = Set(events.map { key(event: $0.name, command: $0.command) })
        let approvals = object["approvals"] as? [[String: Any]] ?? []
        object["approvals"] = approvals.filter { approval in
            guard let event = approval["event"] as? String,
                  let command = approval["command"] as? String else {
                return true
            }
            return !ownedKeys.contains(key(event: event, command: command))
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func decode(_ existing: Data?) throws -> [String: Any] {
        guard let existing, !existing.isEmpty else {
            return ["approvals": []]
        }
        guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            return ["approvals": []]
        }
        return object
    }

    private static func key(event: String, command: String) -> String {
        "\(event)\u{0}\(command)"
    }
}
