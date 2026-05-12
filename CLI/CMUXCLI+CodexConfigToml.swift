import CryptoKit
import Darwin
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
    private static let cmuxCodexHookTrustBegin =
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin"
    private static let cmuxCodexHookTrustEnd =
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end"

    struct CodexHookTrustEntry: Equatable {
        let key: String
        let trustedHash: String
    }

    static func codexConfigTomlInstallingHooksFeature(in existingContent: String) -> String {
        var lines = tomlLines(from: existingContent)
        removeCmuxCodexHooksFeatureBlock(from: &lines)
        removeCmuxCodexHookTrustBlock(from: &lines)
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
        removeCmuxCodexHookTrustBlock(from: &lines)
        lines.removeAll { tomlLineDefinesKey("codex_hooks", line: $0) }
        lines.removeAll { tomlLineDefinesDottedFeaturesKey("codex_hooks", line: $0) }
        removeEmptyFeaturesTable(from: &lines)
        return tomlContent(from: lines)
    }

    static func codexConfigTomlInstallingHookTrust(
        in existingContent: String,
        entries: [CodexHookTrustEntry]
    ) -> String {
        var lines = tomlLines(from: existingContent)
        removeCmuxCodexHookTrustBlock(from: &lines)
        guard !entries.isEmpty else {
            return tomlContent(from: lines)
        }

        if !lines.isEmpty, lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append(cmuxCodexHookTrustBegin)
        for entry in entries {
            lines.append("[hooks.state.\"\(tomlBasicStringContent(entry.key))\"]")
            lines.append("trusted_hash = \"\(tomlBasicStringContent(entry.trustedHash))\"")
        }
        lines.append(cmuxCodexHookTrustEnd)
        return tomlContent(from: lines)
    }

    static func codexHookTrustEntries(
        hooks: [String: Any],
        hooksFilePath: String,
        def: AgentHookDef
    ) -> [CodexHookTrustEntry] {
        guard def.name == "codex" else { return [] }
        let ownedMarkers = hookMarkers(for: def) + feedHookMarkers(for: def)
        let isOwnedCommand: (String) -> Bool = { command in
            ownedMarkers.contains { command.contains($0) }
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
                    let timeoutSec = max(intValue(hook["timeout"]) ?? 600, 1)
                    let statusMessage = hook["statusMessage"] as? String
                    let key = "\(keySource):\(eventLabel):\(groupIndex):\(handlerIndex)"
                    let trustedHash = codexCommandHookHash(
                        eventLabel: eventLabel,
                        matcher: matcher,
                        command: command,
                        timeoutSec: timeoutSec,
                        statusMessage: statusMessage
                    )
                    entries.append(CodexHookTrustEntry(key: key, trustedHash: trustedHash))
                }
            }
        }

        return entries
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
        timeoutSec: Int,
        statusMessage: String?
    ) -> String {
        var handler: [String: Any] = [
            "async": false,
            "command": command,
            "timeout": timeoutSec,
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

    private static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func tomlBasicStringContent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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

    private static func removeCmuxCodexHookTrustBlock(from lines: inout [String]) {
        var index = 0
        while index < lines.count {
            guard lines[index] == cmuxCodexHookTrustBegin else {
                index += 1
                continue
            }

            if let endIndex = lines[index...].firstIndex(of: cmuxCodexHookTrustEnd) {
                lines.removeSubrange(index...endIndex)
            } else {
                var blockEnd = index + 1
                while blockEnd < lines.count {
                    let line = lines[blockEnd]
                    if line == cmuxCodexHookTrustEnd {
                        blockEnd += 1
                        break
                    }
                    if tomlLineIsAnyTableHeader(line),
                       !line.hasPrefix("[hooks.state.") {
                        break
                    }
                    blockEnd += 1
                }
                lines.removeSubrange(index..<blockEnd)
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
        }
    }
}
