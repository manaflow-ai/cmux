import Foundation

public enum DeepSeekTUIHookConfig {
    public struct Event: Equatable {
        public var name: String
        public var command: String
        public var timeoutSecs: Int

        public init(name: String, command: String, timeoutSecs: Int = 5) {
            self.name = name
            self.command = command
            self.timeoutSecs = timeoutSecs
        }
    }

    private static let beginMarker = "# cmux hooks deepseek-tui begin"
    private static let endMarker = "# cmux hooks deepseek-tui end"

    public static func installing(events: [Event], in existing: String) -> String {
        var lines = removingMarkedBlock(normalizedLines(existing))

        if containsHooksTable(lines) {
            lines = ensuringHooksEnabled(lines)
        } else {
            if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                lines.append("")
            }
            lines.append("[hooks]")
            lines.append("enabled = true")
        }

        if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("")
        }
        lines.append(beginMarker)
        for event in events {
            lines.append("[[hooks.hooks]]")
            lines.append("name = \(tomlBasicString("cmux-\(event.name)"))")
            lines.append("event = \(tomlBasicString(event.name))")
            lines.append("command = \(tomlBasicString(event.command))")
            lines.append("timeout_secs = \(event.timeoutSecs)")
            lines.append("")
        }
        if lines.last == "" {
            lines.removeLast()
        }
        lines.append(endMarker)

        return serialized(lines)
    }

    public static func uninstalling(from existing: String) -> String {
        serialized(removingMarkedBlock(normalizedLines(existing)))
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

    private static func containsHooksTable(_ lines: [String]) -> Bool {
        lines.contains { line in
            line.trimmingCharacters(in: .whitespaces)
                .range(of: #"^\[hooks\]\s*(#.*)?$"#, options: .regularExpression) != nil
        }
    }

    private static func ensuringHooksEnabled(_ lines: [String]) -> [String] {
        var result = lines
        guard let tableIndex = result.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespaces)
                .range(of: #"^\[hooks\]\s*(#.*)?$"#, options: .regularExpression) != nil
        }) else {
            return result
        }

        var index = tableIndex + 1
        while index < result.count {
            let trimmed = result[index].trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^enabled\s*="#, options: .regularExpression) != nil {
                let indent = result[index].prefix { $0 == " " || $0 == "\t" }
                result[index] = "\(indent)enabled = true"
                return result
            }
            if trimmed.hasPrefix("[") {
                break
            }
            index += 1
        }

        result.insert("enabled = true", at: tableIndex + 1)
        return result
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

    private static func tomlBasicString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}

public enum DeepSeekTUIHookPayload {
    public static func hookEventName(forSubcommand subcommand: String) -> String {
        switch subcommand {
        case "session-start":
            return "session_start"
        case "prompt-submit":
            return "message_submit"
        case "pre-tool-use":
            return "tool_call_before"
        case "post-tool-use":
            return "tool_call_after"
        case "on-error":
            return "on_error"
        case "stop":
            return "session_end"
        default:
            return subcommand
        }
    }

    public static func jsonObject(
        hookEventName: String,
        environment env: [String: String]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "event": hookEventName,
            "hook_event_name": hookEventName,
        ]

        setString(&object, key: "session_id", value: env["DEEPSEEK_SESSION_ID"])
        setString(&object, key: "cwd", value: env["DEEPSEEK_WORKSPACE"])
        setString(&object, key: "message", value: env["DEEPSEEK_MESSAGE"])
        setString(&object, key: "tool_name", value: env["DEEPSEEK_TOOL_NAME"])
        setString(&object, key: "tool_result", value: env["DEEPSEEK_TOOL_RESULT"])
        setString(&object, key: "mode", value: env["DEEPSEEK_MODE"])
        setString(&object, key: "previous_mode", value: env["DEEPSEEK_PREVIOUS_MODE"])
        setString(&object, key: "error", value: env["DEEPSEEK_ERROR"])
        setString(&object, key: "model", value: env["DEEPSEEK_MODEL"])

        if let toolArgs = normalized(env["DEEPSEEK_TOOL_ARGS"]) {
            object["tool_input"] = decodedJSONValue(toolArgs) ?? toolArgs
        }
        if let exitCode = normalized(env["DEEPSEEK_TOOL_EXIT_CODE"]).flatMap(Int.init) {
            object["tool_exit_code"] = exitCode
        }
        if let success = normalized(env["DEEPSEEK_TOOL_SUCCESS"]) {
            object["tool_success"] = success == "true" || success == "1"
        }
        if let totalTokens = normalized(env["DEEPSEEK_TOTAL_TOKENS"]).flatMap(Int.init) {
            object["total_tokens"] = totalTokens
        }
        if let sessionCost = normalized(env["DEEPSEEK_SESSION_COST"]).flatMap(Double.init) {
            object["session_cost"] = sessionCost
        }

        return object
    }

    public static func jsonString(
        hookEventName: String,
        environment env: [String: String]
    ) -> String {
        let object = jsonObject(hookEventName: hookEventName, environment: env)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func setString(_ object: inout [String: Any], key: String, value: String?) {
        guard let value = normalized(value) else { return }
        object[key] = value
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func decodedJSONValue(_ value: String) -> Any? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
