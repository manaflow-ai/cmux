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

    private struct EventGroup {
        var name: String
        var events: [Event]
    }

    private static let beginMarker = "# cmux hooks hermes-agent begin"
    private static let endMarker = "# cmux hooks hermes-agent end"
    private static let restoreLineMarkerPrefix = "\(beginMarker) restore-line-base64:"

    public static func installing(events: [Event], in existing: String) -> String {
        guard !events.isEmpty else {
            return uninstalling(from: existing)
        }

        var lines = normalizedLines(existing)
        lines = removingMarkedBlocks(lines)

        if let hooksIndex = hooksLineIndex(in: lines) {
            let hooksRestoreLine: String?
            if inlineEmptyHooksLine(lines[hooksIndex]) {
                hooksRestoreLine = lines[hooksIndex]
                lines[hooksIndex] = "\(leadingWhitespace(lines[hooksIndex]))hooks:"
            } else {
                hooksRestoreLine = nil
            }
            let childIndent = hooksChildIndent(in: lines, hooksIndex: hooksIndex)
            let existingEvents = directEventLineIndexes(in: lines, hooksIndex: hooksIndex, childIndent: childIndent)
            var missingEventGroups: [EventGroup] = []
            var matchedEventGroups: [(eventGroup: EventGroup, eventIndex: Int)] = []

            for eventGroup in eventGroupsByNamePreservingOrder(events) {
                guard let eventIndex = existingEvents[eventGroup.name] else {
                    missingEventGroups.append(eventGroup)
                    continue
                }
                matchedEventGroups.append((eventGroup, eventIndex))
            }

            for (eventGroup, eventIndex) in matchedEventGroups.sorted(by: { $0.eventIndex > $1.eventIndex }) {
                let eventRestoreLine: String?
                if inlineEmptyEventLine(lines[eventIndex]) {
                    let originalLine = lines[eventIndex]
                    let headerLine = emptyEventHeaderLine(originalLine)
                    eventRestoreLine = originalLine == headerLine ? nil : originalLine
                    lines[eventIndex] = headerLine
                } else {
                    eventRestoreLine = nil
                }
                let entryIndent = eventEntryIndent(in: lines, eventIndex: eventIndex)
                let block = hookListBlock(events: eventGroup.events, itemIndent: entryIndent, restoreLine: eventRestoreLine)
                lines.insert(contentsOf: block, at: eventIndex + 1)
            }

            if !missingEventGroups.isEmpty {
                let block = eventSectionsBlock(
                    eventGroups: missingEventGroups,
                    childIndent: childIndent,
                    restoreLine: hooksRestoreLine
                )
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

    private static func eventSectionsBlock(
        events: [Event],
        childIndent: String,
        includeMarkers: Bool = true,
        restoreLine: String? = nil
    ) -> [String] {
        eventSectionsBlock(
            eventGroups: eventGroupsByNamePreservingOrder(events),
            childIndent: childIndent,
            includeMarkers: includeMarkers,
            restoreLine: restoreLine
        )
    }

    private static func eventSectionsBlock(
        eventGroups: [EventGroup],
        childIndent: String,
        includeMarkers: Bool = true,
        restoreLine: String? = nil
    ) -> [String] {
        var lines: [String] = []
        if includeMarkers {
            lines.append("\(childIndent)\(beginMarkerLine(restoreLine: restoreLine))")
        }
        for eventGroup in eventGroups {
            lines.append("\(childIndent)\(eventGroup.name):")
            lines.append(contentsOf: hookEntries(events: eventGroup.events, itemIndent: childIndent + "  "))
        }
        if includeMarkers {
            lines.append("\(childIndent)\(endMarker)")
        }
        return lines
    }

    private static func hookListBlock(events: [Event], itemIndent: String, restoreLine: String? = nil) -> [String] {
        var lines = ["\(itemIndent)\(beginMarkerLine(restoreLine: restoreLine))"]
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

    private static func eventGroupsByNamePreservingOrder(_ events: [Event]) -> [EventGroup] {
        var eventGroups: [EventGroup] = []
        var indexesByName: [String: Int] = [:]
        for event in events {
            if let index = indexesByName[event.name] {
                eventGroups[index].events.append(event)
            } else {
                indexesByName[event.name] = eventGroups.count
                eventGroups.append(EventGroup(name: event.name, events: [event]))
            }
        }
        return eventGroups
    }

    /// Removes cmux's marked blocks, keeping whatever another tool wrote inside them.
    ///
    /// When `hooks:` or an event key is missing, the block cmux writes holds
    /// the key itself, so an entry a tool later adds under that key lands
    /// between the markers. Only cmux's entries are dropped, along with a key
    /// they leave with nothing under it.
    private static func removingMarkedBlocks(_ lines: [String]) -> [String] {
        var result = lines
        var index = 0
        while index < result.count {
            guard isBeginMarkerLine(result[index]) else {
                index += 1
                continue
            }
            guard let endIndex = result[(index + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == endMarker
            }) else {
                index += 1
                continue
            }
            let foreignLines = linesFromOtherTools(in: Array(result[(index + 1)..<endIndex]))
            if !foreignLines.isEmpty {
                result.replaceSubrange(index...endIndex, with: foreignLines)
                index += foreignLines.count
                continue
            }
            if let restoreLine = restoreLine(fromBeginMarkerLine: result[index]),
               result.indices.contains(index - 1) {
                result[index - 1] = restoreLine
                result.removeSubrange(index...endIndex)
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

    /// The lines of a marked block that cmux did not write, or none when the
    /// block holds nothing but cmux's entries and the keys above them.
    private static func linesFromOtherTools(in block: [String]) -> [String] {
        var kept: [String] = []
        // Keys that lost a cmux entry. Only these may be dropped when empty,
        // so a line inside another tool's entry is never read as a key.
        var emptiedKeys: Set<Int> = []
        var keyStack: [(indent: Int, keptIndex: Int)] = []

        var index = 0
        while index < block.count {
            let line = block[index]
            let indent = leadingWhitespace(line).count
            guard isListItemLine(line) else {
                if isSignificantLine(line) {
                    keyStack.removeAll { $0.indent >= indent }
                    if isEmptyKeyLine(line) {
                        keyStack.append((indent, kept.count))
                    }
                }
                kept.append(line)
                index += 1
                continue
            }

            // An entry runs to its last deeper line; a comment or blank line
            // in the middle belongs to it.
            var end = index + 1
            var scan = end
            while scan < block.count {
                if isSignificantLine(block[scan]) {
                    guard leadingWhitespace(block[scan]).count > indent else { break }
                    end = scan + 1
                }
                scan += 1
            }
            let item = block[index..<end]
            keyStack.removeAll { $0.indent > indent }
            if isCmuxHookEntry(item) {
                if let parent = keyStack.last {
                    emptiedKeys.insert(parent.keptIndex)
                }
            } else {
                kept.append(contentsOf: item)
            }
            index = end
        }

        // Bottom up, so an event key dropped here can also empty `hooks:`.
        var dropped: Set<Int> = []
        for keyIndex in kept.indices.reversed() where emptiedKeys.contains(keyIndex) {
            let keyIndent = leadingWhitespace(kept[keyIndex]).count
            let child = kept.indices[(keyIndex + 1)...]
                .first { !dropped.contains($0) && isSignificantLine(kept[$0]) }
                .map { kept[$0] }
            let hasChild = child.map { line in
                let indent = leadingWhitespace(line).count
                return indent > keyIndent || (indent == keyIndent && isListItemLine(line))
            } ?? false
            guard !hasChild else { continue }
            dropped.insert(keyIndex)
            if let parent = kept.indices[..<keyIndex].last(where: {
                !dropped.contains($0) && isEmptyKeyLine(kept[$0])
                    && leadingWhitespace(kept[$0]).count < keyIndent
            }) {
                emptiedKeys.insert(parent)
            }
        }
        let remaining = kept.indices.filter { !dropped.contains($0) }.map { kept[$0] }
        return remaining.contains(where: isSignificantLine) ? remaining : []
    }

    /// Whether a hook entry inside the markers is cmux's.
    ///
    /// Every command cmux has written here runs its CLI, so an entry that
    /// names cmux anywhere counts. Reading it that broadly means a cmux entry
    /// in an older or newer form is never kept as another tool's and then
    /// written a second time.
    private static func isCmuxHookEntry(_ item: ArraySlice<String>) -> Bool {
        item.contains { $0.range(of: "cmux", options: .caseInsensitive) != nil }
    }

    private static func isListItemLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "-" || trimmed.hasPrefix("- ")
    }

    /// Whether a line holds YAML content, not just whitespace or a comment.
    private static func isSignificantLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    /// Whether a line is a mapping key with no value on its own line.
    private static func isEmptyKeyLine(_ line: String) -> Bool {
        guard isSignificantLine(line), !isListItemLine(line) else { return false }
        let uncommented = line.range(of: #"\s+#.*$"#, options: .regularExpression)
            .map { line[..<$0.lowerBound] } ?? line[...]
        return uncommented.hasSuffix(":")
    }

    private static func beginMarkerLine(restoreLine: String?) -> String {
        guard let restoreLine else { return beginMarker }
        let encoded = Data(restoreLine.utf8).base64EncodedString()
        return "\(restoreLineMarkerPrefix) \(encoded)"
    }

    private static func isBeginMarkerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == beginMarker || trimmed.hasPrefix("\(restoreLineMarkerPrefix) ")
    }

    private static func restoreLine(fromBeginMarkerLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(restoreLineMarkerPrefix) ") else { return nil }
        let encoded = trimmed.dropFirst(restoreLineMarkerPrefix.count)
            .trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func hooksLineIndex(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            leadingWhitespace(line).isEmpty
                && line.range(of: #"^hooks:\s*((\{\}|\[\])\s*)?(#.*)?$"#, options: .regularExpression) != nil
        }
    }

    private static func inlineEmptyHooksLine(_ line: String) -> Bool {
        line.range(of: #"^hooks:\s*(\{\}|\[\])\s*(#.*)?$"#, options: .regularExpression) != nil
    }

    private static func inlineEmptyEventLine(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let suffix = line[line.index(after: colon)...]
        return suffixIsInlineEmptyMapOrList(suffix)
    }

    private static func emptyEventHeaderLine(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        return String(line[...colon])
    }

    private static func suffixIsInlineEmptyMapOrList(_ suffix: Substring) -> Bool {
        let uncommented = suffix.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let trimmed = uncommented.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "{}" || trimmed == "[]"
    }

    /// The indent the children of `hooks:` already use, or two spaces past it.
    private static func hooksChildIndent(in lines: [String], hooksIndex: Int) -> String {
        let hooksIndent = leadingWhitespace(lines[hooksIndex])
        if let child = lines[(hooksIndex + 1)...].first(where: isSignificantLine),
           !isListItemLine(child) {
            let indent = leadingWhitespace(child)
            if indent.count > hooksIndent.count, indent.hasPrefix(hooksIndent) {
                return indent
            }
        }
        return hooksIndent + "  "
    }

    /// The indent the entries under an event key already use, or two spaces
    /// past the key. A list may sit at the same indent as its key.
    private static func eventEntryIndent(in lines: [String], eventIndex: Int) -> String {
        let eventIndent = leadingWhitespace(lines[eventIndex])
        if let child = lines[(eventIndex + 1)...].first(where: isSignificantLine),
           isListItemLine(child) {
            let indent = leadingWhitespace(child)
            if indent.hasPrefix(eventIndent) {
                return indent
            }
        }
        return eventIndent + "  "
    }

    private static func directEventLineIndexes(
        in lines: [String],
        hooksIndex: Int,
        childIndent: String
    ) -> [String: Int] {
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
            if suffixIsInlineEmptyMapOrList(suffix) {
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
    enum Error: Swift.Error, Equatable {
        case invalidRoot
    }

    public static func installing(events: [HermesAgentHookConfig.Event], in existing: Data?, approvedAt: Date = Date()) throws -> Data {
        var object = try decode(existing)
        let approvals = object["approvals"] as? [[String: Any]] ?? []
        let installedKeys = Set(events.map { key(event: $0.name, command: $0.command) })
        var keyed: [String: [String: Any]] = [:]
        var passthrough: [[String: Any]] = []
        for approval in approvals {
            guard let event = approval["event"] as? String,
                  let command = approval["command"] as? String else {
                passthrough.append(approval)
                continue
            }
            let approvalKey = key(event: event, command: command)
            if isCmuxOwnedCommand(command), !installedKeys.contains(approvalKey) {
                continue
            }
            keyed[approvalKey] = approval
        }

        let iso = ISO8601DateFormatter().string(from: approvedAt)
        for event in events {
            let eventKey = key(event: event.name, command: event.command)
            guard keyed[eventKey] == nil else { continue }
            keyed[eventKey] = [
                "event": event.name,
                "command": event.command,
                "approved_at": iso,
            ]
        }
        let ownedApprovals = keyed.values.sorted {
            (($0["event"] as? String) ?? "", ($0["command"] as? String) ?? "")
                < ((($1["event"] as? String) ?? ""), (($1["command"] as? String) ?? ""))
        }
        object["approvals"] = passthrough + ownedApprovals
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
                && !isCmuxOwnedCommand(command)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func decode(_ existing: Data?) throws -> [String: Any] {
        guard let existing, !existing.isEmpty else {
            return ["approvals": []]
        }
        guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw Error.invalidRoot
        }
        return object
    }

    private static func key(event: String, command: String) -> String {
        "\(event)\u{0}\(command)"
    }

    private static func isCmuxOwnedCommand(_ command: String) -> Bool {
        HermesAgentHookCommandOwnership().containsOwnedCommand(command)
    }
}
