import Foundation

extension CMUXCLI {
    func parseClaudeHookInput(rawInput: String) -> ClaudeHookParsedInput {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            let fallback = trimmed.isEmpty ? nil : truncate(
                normalizedSingleLine(redactClaudeSensitiveSpans(trimmed)),
                maxLength: 180
            )
            return ClaudeHookParsedInput(
                rawObject: nil,
                object: nil,
                rawFallback: fallback,
                sessionId: nil,
                turnId: nil,
                cwd: nil,
                transcriptPath: nil
            )
        }

        let sessionId = extractClaudeHookSessionId(from: object)
        let turnId = firstString(in: object, keys: ["turn_id", "turnId"])
        let cwd = extractClaudeHookCWD(from: object)
        let transcriptPath = extractHookTranscriptPath(from: object)
        let compactObject = compactClaudeHookObject(object)
        return ClaudeHookParsedInput(
            rawObject: object,
            object: compactObject,
            rawFallback: nil,
            sessionId: sessionId,
            turnId: turnId,
            cwd: cwd,
            transcriptPath: transcriptPath
        )
    }

    private func compactClaudeHookObject(_ object: [String: Any]) -> [String: Any] {
        var compact: [String: Any] = [:]

        for key in [
            "tool_name", "toolName", "turn_id", "turnId", "conversation_id", "conversationId", "transcript_path", "transcriptPath",
            "last_assistant_message", "lastAssistantMessage", "assistantPreamble", "assistant_preamble", "assistant_response", "assistantResponse",
            "event", "event_name", "hook_event_name", "hookEventName", "type", "kind", "notification_type", "matcher", "reason", "source", "terminationReason",
            "title", "summary", "message", "body", "text", "prompt", "error", "codex_error_info", "codexErrorInfo",
            "additional_details", "additionalDetails", "description",
            "campfire_event_type", "campfireEventType", "display_name", "displayName", "capability",
        ] {
            if let value = compactClaudeHookValue(object[key], key: key) {
                compact[key] = value
            }
        }

        if let toolInput = object["tool_input"] as? [String: Any] {
            var compactToolInput: [String: Any] = [:]
            for key in ["file_path", "command", "pattern", "description", "query", "plan", "planFilePath"] {
                if let value = compactClaudeHookToolInputValue(toolInput[key], key: key) {
                    compactToolInput[key] = value
                }
            }
            if let allowedPrompts = toolInput["allowedPrompts"] as? [[String: Any]] {
                let compactPrompts: [[String: String]] = allowedPrompts.compactMap { prompt in
                    guard let promptText = compactClaudeHookStringValue(prompt["prompt"], maxLength: 220) else {
                        return nil
                    }
                    var out: [String: String] = ["prompt": promptText]
                    if let tool = compactClaudeHookStringValue(prompt["tool"], maxLength: 80) {
                        out["tool"] = tool
                    }
                    return out
                }
                if !compactPrompts.isEmpty {
                    compactToolInput["allowedPrompts"] = compactPrompts
                }
            }
            if let questions = toolInput["questions"] as? [[String: Any]] {
                compactToolInput["questions"] = questions.prefix(1).map { question in
                    var compactQuestion: [String: Any] = [:]
                    if let value = compactClaudeHookStringValue(question["question"], maxLength: 180) {
                        compactQuestion["question"] = value
                    }
                    if let value = compactClaudeHookStringValue(question["header"], maxLength: 80) {
                        compactQuestion["header"] = value
                    }
                    if let options = question["options"] as? [[String: Any]] {
                        let compactOptions: [[String: Any]] = options.compactMap { option in
                            guard let label = compactClaudeHookStringValue(option["label"], maxLength: 60) else {
                                return nil
                            }
                            return ["label": label] as [String: Any]
                        }
                        compactQuestion["options"] = compactOptions
                    }
                    return compactQuestion
                }
            }
            if !compactToolInput.isEmpty {
                compact["tool_input"] = compactToolInput
            }
        }

        for key in ["notification", "data"] {
            guard let nested = object[key] as? [String: Any] else { continue }
            var compactNested: [String: Any] = [:]
            for nestedKey in [
                "type", "kind", "reason", "title", "summary", "message", "body", "text", "prompt", "error", "conversation_id", "conversationId", "transcript_path", "transcriptPath",
                "codex_error_info", "codexErrorInfo", "additional_details", "additionalDetails", "description",
            ] {
                if let value = compactClaudeHookValue(nested[nestedKey], key: nestedKey) {
                    compactNested[nestedKey] = value
                }
            }
            if !compactNested.isEmpty {
                compact[key] = compactNested
            }
        }

        if let extra = object["extra"] as? [String: Any] {
            var compactExtra: [String: Any] = [:]
            for extraKey in [
                "assistant_response", "assistantResponse", "last_assistant_message", "lastAssistantMessage",
                "assistantPreamble", "assistant_preamble", "user_message", "userMessage",
                "title", "command", "description", "pattern_key", "patternKey",
                "surface", "choice", "message", "body", "text", "prompt", "summary", "error",
                "campfire_event_type", "campfireEventType", "display_name", "displayName", "capability",
            ] {
                if let value = compactClaudeHookValue(extra[extraKey], key: extraKey) {
                    compactExtra[extraKey] = value
                }
            }
            if !compactExtra.isEmpty {
                compact["extra"] = compactExtra
            }
        }

        return compact
    }

    private func claudeHookCompactFieldLimit(for key: String) -> Int {
        switch key {
        case "tool_name", "toolName", "turn_id", "turnId", "conversation_id", "conversationId", "event", "event_name", "hook_event_name", "hookEventName", "type", "kind", "notification_type", "matcher", "reason", "source", "campfire_event_type", "campfireEventType", "capability":
            return 80
        case "transcript_path", "transcriptPath":
            return 240
        case "last_assistant_message", "lastAssistantMessage", "assistantPreamble", "assistant_preamble", "assistant_response", "assistantResponse", "title", "summary", "message", "body", "text", "prompt", "error", "codex_error_info", "codexErrorInfo", "additional_details", "additionalDetails", "description", "terminationReason", "user_message", "userMessage", "command":
            return 240
        case "display_name", "displayName":
            return 120
        default:
            return 160
        }
    }

    private func compactClaudeHookValue(_ rawValue: Any?, key: String) -> String? {
        switch key {
        case "error", "codex_error_info", "codexErrorInfo", "additional_details", "additionalDetails":
            return compactClaudeHookCodexFailureValue(rawValue, key: key)
        default:
            return compactClaudeHookStringValue(rawValue, maxLength: claudeHookCompactFieldLimit(for: key))
        }
    }

    private func compactClaudeHookCodexFailureValue(_ rawValue: Any?, key: String) -> String? {
        let maxLength = claudeHookCompactFieldLimit(for: key)
        if let string = compactClaudeHookStringValue(rawValue, maxLength: maxLength) {
            return string
        }
        guard let rawValue,
              JSONSerialization.isValidJSONObject(rawValue),
              let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return compactClaudeHookStringValue(string, maxLength: maxLength)
    }

    private func compactClaudeHookToolInputValue(_ rawValue: Any?, key: String) -> String? {
        switch key {
        case "file_path":
            return compactClaudeHookStringValue(rawValue, maxLength: 240, keepSuffix: true)
        case "planFilePath":
            return compactClaudeHookStringValue(rawValue, maxLength: 240, keepSuffix: true)
        case "command":
            return compactClaudeHookStringValue(rawValue, maxLength: 120)
        case "plan":
            return compactClaudeHookStringValue(rawValue, maxLength: 4_000)
        case "pattern", "query":
            return compactClaudeHookStringValue(rawValue, maxLength: 120)
        case "description":
            return compactClaudeHookStringValue(rawValue, maxLength: 180)
        default:
            return compactClaudeHookStringValue(rawValue, maxLength: 160)
        }
    }

    private func compactClaudeHookStringValue(
        _ rawValue: Any?,
        maxLength: Int,
        keepSuffix: Bool = false
    ) -> String? {
        guard let rawString = rawValue as? String else { return nil }
        let previewLength = max(maxLength, min(maxLength * 4, 1024))
        let preview = keepSuffix
            ? String(rawString.suffix(previewLength))
            : String(rawString.prefix(previewLength))
        let normalized = normalizedSingleLine(preview)
        guard !normalized.isEmpty else { return nil }
        if keepSuffix, normalized.count > maxLength {
            return "…" + String(normalized.suffix(maxLength - 1))
        }
        return truncate(normalized, maxLength: maxLength)
    }

    func extractClaudeHookSessionId(from object: [String: Any]) -> String? {
        let sessionIDKeys = ["session_id", "sessionId", "conversation_id", "conversationId"]
        if let id = firstString(in: object, keys: sessionIDKeys) {
            return id
        }

        if let nested = object["notification"] as? [String: Any],
           let id = firstString(in: nested, keys: sessionIDKeys) {
            return id
        }
        if let nested = object["data"] as? [String: Any],
           let id = firstString(in: nested, keys: sessionIDKeys) {
            return id
        }
        if let session = object["session"] as? [String: Any],
           let id = firstString(in: session, keys: ["id"] + sessionIDKeys) {
            return id
        }
        if let context = object["context"] as? [String: Any],
           let id = firstString(in: context, keys: sessionIDKeys) {
            return id
        }
        return nil
    }

    func extractHookTranscriptPath(from object: [String: Any]) -> String? {
        let transcriptPathKeys = ["transcript_path", "transcriptPath"]
        if let transcriptPath = firstString(in: object, keys: transcriptPathKeys) {
            return transcriptPath
        }
        if let nested = object["notification"] as? [String: Any],
           let transcriptPath = firstString(in: nested, keys: transcriptPathKeys) {
            return transcriptPath
        }
        if let nested = object["data"] as? [String: Any],
           let transcriptPath = firstString(in: nested, keys: transcriptPathKeys) {
            return transcriptPath
        }
        if let context = object["context"] as? [String: Any],
           let transcriptPath = firstString(in: context, keys: transcriptPathKeys) {
            return transcriptPath
        }
        return nil
    }

    func extractClaudeHookCWD(from object: [String: Any]) -> String? {
        let cwdKeys = ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir", "project_path", "projectPath"]
        if let cwd = firstString(in: object, keys: cwdKeys) {
            return cwd
        }
        if let cwd = firstWorkspacePath(in: object) {
            return cwd
        }
        if let nested = object["notification"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["notification"] as? [String: Any],
           let cwd = firstWorkspacePath(in: nested) {
            return cwd
        }
        if let nested = object["data"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["data"] as? [String: Any],
           let cwd = firstWorkspacePath(in: nested) {
            return cwd
        }
        if let context = object["context"] as? [String: Any],
           let cwd = firstString(in: context, keys: cwdKeys) {
            return cwd
        }
        if let context = object["context"] as? [String: Any],
           let cwd = firstWorkspacePath(in: context) {
            return cwd
        }
        return nil
    }

    func firstWorkspacePath(in object: [String: Any]) -> String? {
        let rawPaths = object["workspacePaths"] ?? object["workspace_paths"]
        guard let paths = rawPaths as? [Any] else { return nil }
        for path in paths {
            guard let string = path as? String else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    func readRecentTextFileLines(
        path: String,
        maxBytes: UInt64
    ) -> [String]? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        defer { try? handle.close() }

        func isASCIIWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
        }

        func hasCompleteLineAfterLeadingBoundary(_ data: Data, readStart: UInt64) -> Bool {
            guard readStart > 0 else { return true }
            guard let newline = data.firstIndex(of: 0x0A) else { return false }
            return data[data.index(after: newline)...].contains { !isASCIIWhitespace($0) }
        }

        let size: UInt64
        do {
            size = try handle.seekToEnd()
            var readStart = size > maxBytes ? size - maxBytes : 0
            try handle.seek(toOffset: readStart)
            guard var data = try handle.readToEnd(), !data.isEmpty else {
                return nil
            }
            let maxWindowBytes = maxBytes > UInt64.max / 8 ? UInt64.max : maxBytes * 8

            while !hasCompleteLineAfterLeadingBoundary(data, readStart: readStart), readStart > 0 {
                let currentWindowBytes = size - readStart
                guard currentWindowBytes < maxWindowBytes else { break }
                let remainingWindowBytes = maxWindowBytes - currentWindowBytes
                let expansionBytes = min(readStart, maxBytes, remainingWindowBytes)
                guard expansionBytes > 0 else { break }

                readStart -= expansionBytes
                try handle.seek(toOffset: readStart)
                guard let expandedData = try handle.readToEnd(), !expandedData.isEmpty else {
                    return nil
                }
                data = expandedData
            }

            if readStart > 0, let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...newline)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text.components(separatedBy: "\n")
        } catch {
            return nil
        }
    }

    func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    func normalizedSingleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }

    func redactClaudeSensitiveSpans(_ value: String) -> String {
        let patterns: [(pattern: String, replacement: String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
            (#"(?:~|/)[^\s\"']+"#, "<path>"),
            (#"\b(?:sk|rk|sess|token|key|secret|api[_-]?key)[A-Za-z0-9._:-]{8,}\b"#, "<token>"),
            (#"\b[A-Za-z0-9_-]{24,}\b"#, "<token>")
        ]
        return patterns.reduce(value) { partial, entry in
            partial.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }
}
