import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Codex config.toml hook editing
extension CMUXCLI {
    static func appendCmuxHookInsertionIndex(
        _ index: Int,
        for event: String,
        to indexes: inout [String: [Int]]
    ) {
        if indexes[event]?.isEmpty == false { return }
        indexes[event, default: []].append(index)
    }

    static func insertCmuxHookValues<T>(_ values: [T], into target: inout [T], atOriginalIndexes indexes: [Int]) {
        var insertedCount = 0
        for originalIndex in indexes {
            let insertionIndex = min(max(originalIndex + insertedCount, 0), target.count)
            target.insert(contentsOf: values, at: insertionIndex)
            insertedCount += values.count
        }
    }

    private static let cmuxCodexHooksFeatureBegin =
        "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df begin"
    private static let cmuxCodexHooksFeatureEnd =
        "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df end"
    private static let cmuxCodexHooksFeaturePreviousLinePrefix =
        "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df previous line: "
    private static let legacyCmuxCodexHooksFeatureBegin = "# cmux hooks codex feature begin"
    private static let legacyCmuxCodexHooksFeatureEnd = "# cmux hooks codex feature end"
    private static let legacyCmuxCodexHooksFeaturePreviousLinePrefix =
        "# cmux hooks codex feature previous line: "
    private static let cmuxCodexHookTrustBegin =
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin"
    private static let cmuxCodexHookTrustEnd =
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end"
    private static let codexHookTrustTableHeaderRegex = try! NSRegularExpression(
        pattern: #"^\s*\[\s*hooks\s*\.\s*state\s*\.\s*"((?:[^"\\\n]|\\.)*)"\s*\]\s*(#.*)?$"#
    )

    struct CodexHookTrustEntry: Equatable {
        let key: String
        let trustedHash: String
    }

    struct CodexHookTrustInstallResult: Equatable {
        let content: String
        let installedTrust: Bool
    }

    private enum CodexHookTrustBlockRemovalResult {
        case notFound
        case removed
        case malformed
    }

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

    static func codexConfigTomlUninstallingHooksFeature(
        from existingContent: String,
        removingHookTrustEntries entries: [CodexHookTrustEntry] = [],
        removingEscapedKeyPrefixes escapedKeyPrefixes: Set<String> = [],
        removingTrustedHashes additionalTrustedHashes: Set<String> = []
    ) -> String {
        var lines = tomlLines(from: existingContent)
        let escapedKeys = Set(entries.map { tomlBasicStringContent($0.key) })
        let trustedHashes = Set(entries.map(\.trustedHash)).union(additionalTrustedHashes)
        removeCmuxCodexHooksFeatureBlock(from: &lines)
        if removeCmuxCodexHookTrustBlock(
            from: &lines,
            removingEscapedKeys: escapedKeys,
            removingEscapedKeyPrefixes: escapedKeyPrefixes,
            removingTrustedHashes: trustedHashes
        ) == .malformed {
            stripMalformedCmuxCodexHookTrustMarker(from: &lines)
        }
        removeCodexHookTrustTables(withEscapedKeys: escapedKeys, from: &lines)
        lines.removeAll { tomlLineDefinesKey("codex_hooks", line: $0) }
        lines.removeAll { tomlLineDefinesDottedFeaturesKey("codex_hooks", line: $0) }
        removeEmptyFeaturesTable(from: &lines)
        return tomlContent(from: lines)
    }

    static func codexConfigTomlRemovingHookTrust(
        in existingContent: String,
        entries: [CodexHookTrustEntry],
        removingEscapedKeyPrefixes escapedKeyPrefixes: Set<String>,
        removingTrustedHashes additionalTrustedHashes: Set<String> = []
    ) -> String {
        var lines = tomlLines(from: existingContent)
        let escapedKeys = Set(entries.map { tomlBasicStringContent($0.key) })
        let trustedHashes = Set(entries.map(\.trustedHash)).union(additionalTrustedHashes)
        let removalResult = removeCmuxCodexHookTrustBlock(
            from: &lines,
            removingEscapedKeys: escapedKeys,
            removingEscapedKeyPrefixes: escapedKeyPrefixes,
            removingTrustedHashes: trustedHashes
        )
        if removalResult == .malformed {
            stripMalformedCmuxCodexHookTrustMarker(from: &lines)
        }
        removeCodexHookTrustTables(withEscapedKeys: escapedKeys, from: &lines)
        return tomlContent(from: lines)
    }

    static func codexConfigTomlInstallingHookTrust(
        in existingContent: String,
        entries: [CodexHookTrustEntry],
        removingEscapedKeyPrefixes escapedKeyPrefixes: Set<String> = [],
        removingTrustedHashes additionalTrustedHashes: Set<String> = []
    ) -> CodexHookTrustInstallResult {
        var lines = tomlLines(from: existingContent)
        let escapedKeys = Set(entries.map { tomlBasicStringContent($0.key) })
        let trustedHashes = Set(entries.map(\.trustedHash)).union(additionalTrustedHashes)
        let removalResult = removeCmuxCodexHookTrustBlock(
            from: &lines,
            removingEscapedKeys: escapedKeys,
            removingEscapedKeyPrefixes: escapedKeyPrefixes,
            removingTrustedHashes: trustedHashes
        )
        if removalResult == .malformed {
            stripMalformedCmuxCodexHookTrustMarker(from: &lines)
        }
        guard !entries.isEmpty else {
            return CodexHookTrustInstallResult(content: tomlContent(from: lines), installedTrust: false)
        }
        removeCodexHookTrustTables(withEscapedKeys: escapedKeys, from: &lines)

        if !lines.isEmpty, lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append(cmuxCodexHookTrustBegin)
        for entry in entries {
            lines.append("[hooks.state.\"\(tomlBasicStringContent(entry.key))\"]")
            lines.append("trusted_hash = \"\(tomlBasicStringContent(entry.trustedHash))\"")
        }
        lines.append(cmuxCodexHookTrustEnd)
        return CodexHookTrustInstallResult(content: tomlContent(from: lines), installedTrust: true)
    }

    static func codexHookTrustEntries(
        hooks: [String: Any],
        hooksFilePath: String,
        def: AgentHookDef,
        includeLegacyOwnedCommands: Bool = false
    ) -> [CodexHookTrustEntry] {
        guard def.name == "codex" else { return [] }
        let isOwnedCommand: (String) -> Bool = { command in
            isCmuxOwnedHookCommand(command, for: def, includeLegacy: includeLegacyOwnedCommands)
        }
        var entries: [CodexHookTrustEntry] = []
        let keySource = codexNormalizedHookSourcePath(hooksFilePath)

        for eventName in codexHookEventNames {
            guard let groups = hooks[eventName] as? [[String: Any]],
                  let eventLabel = codexHookEventLabel(eventName) else {
                continue
            }
            for (groupIndex, group) in groups.enumerated() {
                guard let hookList = group["hooks"] as? [[String: Any]] else { continue }
                let matcher = codexHookEventUsesMatcher(eventName) ? group["matcher"] as? String : nil
                for (handlerIndex, hook) in hookList.enumerated() {
                    guard let command = hook["command"] as? String,
                          isOwnedCommand(command) else {
                        continue
                    }
                    let timeoutMs = max(intValue(hook["timeout"]) ?? 600, 1)
                    let statusMessage = hook["statusMessage"] as? String
                    let key = "\(keySource):\(eventLabel):\(groupIndex):\(handlerIndex)"
                    let trustedHash = codexCommandHookHash(
                        eventLabel: eventLabel,
                        matcher: matcher,
                        command: command,
                        timeoutMs: timeoutMs,
                        statusMessage: statusMessage
                    )
                    entries.append(CodexHookTrustEntry(key: key, trustedHash: trustedHash))
                }
            }
        }

        return entries
    }

    static func codexHookTrustEscapedKeyPrefixes(
        hooksFilePath: String,
        def: AgentHookDef
    ) -> Set<String> {
        guard def.name == "codex" else { return [] }
        return [tomlBasicStringContent("\(codexNormalizedHookSourcePath(hooksFilePath)):")]
    }

    static func codexLegacyHookTrustHashes(def: AgentHookDef) -> Set<String> {
        guard def.name == "codex" else { return [] }
        let hookTimeoutMs: Int
        if case .nested(let timeoutMs) = def.format {
            hookTimeoutMs = timeoutMs
        } else {
            hookTimeoutMs = 600
        }

        var hashes = Set<String>()
        func insertHashes(eventLabel: String, command: String, timeouts: [Int]) {
            let commands = [
                command,
                "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && \(command) || echo '{}'",
            ]
            for command in commands {
                for timeout in timeouts {
                    hashes.insert(codexCommandHookHash(
                        eventLabel: eventLabel,
                        matcher: nil,
                        command: command,
                        timeoutMs: timeout,
                        statusMessage: nil
                    ))
                }
            }
        }

        for event in def.events {
            guard let eventLabel = codexHookEventLabel(event.agentEvent) else { continue }
            insertHashes(
                eventLabel: eventLabel,
                command: Self.hookCommandString(for: def, event: event),
                timeouts: [5_000, 600]
            )
            insertHashes(
                eventLabel: eventLabel,
                command: "cmux codex-hook \(event.cmuxSubcommand)",
                timeouts: [hookTimeoutMs, 600]
            )
        }

        for agentEvent in def.feedHookEvents {
            guard let eventLabel = codexHookEventLabel(agentEvent) else { continue }
            insertHashes(
                eventLabel: eventLabel,
                command: Self.feedHookCommandString(for: def, agentEvent: agentEvent),
                timeouts: [120_000, 120, 600]
            )
            insertHashes(
                eventLabel: eventLabel,
                command: "cmux feed-hook --source \(def.name) --event \(agentEvent)",
                timeouts: [120_000, 600]
            )
        }
        return hashes
    }

    private static func codexNormalizedHookSourcePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let resolved = realPath(url.path) {
            return resolved
        }
        let parent = url.deletingLastPathComponent()
        if let resolvedParent = realPath(parent.path) {
            return URL(fileURLWithPath: resolvedParent, isDirectory: true)
                .appendingPathComponent(url.lastPathComponent)
                .path
        }
        return url.path
    }

    private static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    private static let codexHookEventNames = [
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PreCompact",
        "PostCompact",
        "SessionStart",
        "UserPromptSubmit",
        "Stop",
    ]

    private static func codexHookEventLabel(_ eventName: String) -> String? {
        switch eventName {
        case "PreToolUse": return "pre_tool_use"
        case "PermissionRequest": return "permission_request"
        case "PostToolUse": return "post_tool_use"
        case "PreCompact": return "pre_compact"
        case "PostCompact": return "post_compact"
        case "SessionStart": return "session_start"
        case "UserPromptSubmit": return "user_prompt_submit"
        case "Stop": return "stop"
        default: return nil
        }
    }

    private static func codexHookEventUsesMatcher(_ eventName: String) -> Bool {
        switch eventName {
        case "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact", "SessionStart":
            return true
        default:
            return false
        }
    }

    private static func codexCommandHookHash(
        eventLabel: String,
        matcher: String?,
        command: String,
        timeoutMs: Int,
        statusMessage: String?
    ) -> String {
        let normalizedTimeoutMs = max(timeoutMs, 1)
        var handler: [String: Any] = [
            "async": false,
            "command": command,
            "timeout": normalizedTimeoutMs,
            "type": "command",
        ]
        if let statusMessage {
            handler["statusMessage"] = statusMessage
        }
        var identity: [String: Any] = [
            "event_name": eventLabel,
            "hooks": [handler],
        ]
        if let matcher {
            identity["matcher"] = matcher
        }

        let data = (try? JSONSerialization.data(
            withJSONObject: identity,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
    }

    private static func tomlBasicStringContent(_ value: String) -> String {
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
                var blockEnd = index + 1
                var previousLines: [String] = []
                if blockEnd < lines.count,
                   let previousLine = tomlCodexHooksFeaturePreviousLine(from: lines[blockEnd])
                {
                    previousLines.append(previousLine)
                    blockEnd += 1
                }
                if blockEnd < lines.count, tomlLineIsCodexHooksFeatureSetting(lines[blockEnd]) {
                    blockEnd += 1
                }
                lines.replaceSubrange(index..<blockEnd, with: previousLines)
            }
        }
    }

    @discardableResult
    private static func removeCmuxCodexHookTrustBlock(
        from lines: inout [String],
        removingEscapedKeys escapedKeys: Set<String> = [],
        removingEscapedKeyPrefixes escapedKeyPrefixes: Set<String> = [],
        removingTrustedHashes trustedHashes: Set<String> = []
    ) -> CodexHookTrustBlockRemovalResult {
        var replacements: [(range: ClosedRange<Int>, lines: [String])] = []
        var index = 0
        while index < lines.count {
            guard lines[index] == cmuxCodexHookTrustBegin else {
                index += 1
                continue
            }

            guard let endIndex = lines[index...].firstIndex(of: cmuxCodexHookTrustEnd) else {
                return .malformed
            }
            let preservedLines = codexHookTrustBlockUnownedLines(
                from: lines[(index + 1)..<endIndex],
                removingEscapedKeys: escapedKeys,
                removingEscapedKeyPrefixes: escapedKeyPrefixes,
                removingTrustedHashes: trustedHashes
            )
            replacements.append((index...endIndex, preservedLines))
            index = endIndex + 1
        }

        for replacement in replacements.reversed() {
            lines.replaceSubrange(replacement.range, with: replacement.lines)
        }
        return replacements.isEmpty ? .notFound : .removed
    }

    private static func codexHookTrustBlockUnownedLines(
        from lines: ArraySlice<String>,
        removingEscapedKeys escapedKeys: Set<String>,
        removingEscapedKeyPrefixes escapedKeyPrefixes: Set<String>,
        removingTrustedHashes trustedHashes: Set<String>
    ) -> [String] {
        var preserved: [String] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            if let escapedKey = codexHookTrustTableEscapedKey(from: lines[index]) {
                let tableStart = index
                index += 1
                while index < lines.endIndex, !tomlLineIsCodexHookTrustBlockTableBoundary(lines[index]) {
                    index += 1
                }
                if !codexHookTrustEscapedKeyIsRemoved(
                    escapedKey,
                    trustedHash: codexHookTrustTrustedHash(from: lines[tableStart..<index]),
                    removingEscapedKeys: escapedKeys,
                    removingEscapedKeyPrefixes: escapedKeyPrefixes,
                    removingTrustedHashes: trustedHashes
                ) {
                    preserved.append(contentsOf: lines[tableStart..<index])
                }
                continue
            }

            guard tomlLineIsAnyTableHeader(lines[index]) else {
                // Marker drift can capture user config lines; only cmux-owned
                // hook trust tables are safe to discard.
                preserved.append(lines[index])
                index += 1
                continue
            }
            let tableStart = index
            index += 1
            while index < lines.endIndex, !tomlLineIsCodexHookTrustBlockTableBoundary(lines[index]) {
                index += 1
            }
            preserved.append(contentsOf: lines[tableStart..<index])
        }
        return preserved
    }

    private static func codexHookTrustEscapedKeyIsRemoved(
        _ escapedKey: String,
        trustedHash: String?,
        removingEscapedKeys escapedKeys: Set<String>,
        removingEscapedKeyPrefixes escapedKeyPrefixes: Set<String>,
        removingTrustedHashes trustedHashes: Set<String>
    ) -> Bool {
        if escapedKeys.contains(escapedKey) {
            return true
        }
        guard let trustedHash, trustedHashes.contains(trustedHash) else {
            return false
        }
        return escapedKeyPrefixes.contains { escapedKey.hasPrefix($0) }
    }

    private static func codexHookTrustTrustedHash(from lines: ArraySlice<String>) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            guard key == "trusted_hash" else { continue }
            let valueStart = trimmed.index(after: equalsIndex)
            let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { continue }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    private static func stripMalformedCmuxCodexHookTrustMarker(from lines: inout [String]) {
        lines.removeAll { $0 == cmuxCodexHookTrustBegin }
    }

    private static func removeCodexHookTrustTables(withEscapedKeys keys: Set<String>, from lines: inout [String]) {
        guard !keys.isEmpty else { return }
        var index = 0
        while index < lines.count {
            guard let escapedKey = codexHookTrustTableEscapedKey(from: lines[index]),
                  keys.contains(escapedKey) else {
                index += 1
                continue
            }
            let endIndex = codexHookTrustTableEndIndex(in: lines, after: index)
            lines.removeSubrange(index..<endIndex)
        }
    }

    private static func codexHookTrustTableEndIndex(in lines: [String], after tableStart: Int) -> Int {
        var index = tableStart + 1
        while index < lines.count {
            if tomlLineIsCodexHookTrustBlockTableBoundary(lines[index]) {
                return index
            }
            index += 1
        }
        return lines.count
    }

    private static func codexHookTrustTableEscapedKey(from line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = codexHookTrustTableHeaderRegex.firstMatch(in: line, range: range),
              let keyRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[keyRange])
    }

    private static func tomlLineIsCodexHookTrustBlockTableBoundary(_ line: String) -> Bool {
        codexHookTrustTableEscapedKey(from: line) != nil || tomlLineIsAnyTableHeader(line)
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

    private static func tomlLineIsCodexHooksFeatureSetting(_ line: String) -> Bool {
        tomlLineDefinesTrueKey("hooks", line: line)
            || tomlLineDefinesDottedFeaturesTrueKey("hooks", line: line)
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

    // MARK: Generic hook handler

}
