public import Foundation

/// Parses cmux.json `actions` into command actions cmux-next can run.
/// Types the new app cannot run yet (`workspaceCommand`, `workspace`) are
/// reported and skipped; nothing throws.
enum ConfigActionParser {
    nonisolated static func parseActions(_ root: JSONValue, configDirectory: URL,
                                         diagnostics: inout [SettingsDiagnostic]) -> [String: ConfigCommandAction] {
        guard let section = root["actions"] else { return [:] }
        guard case .object(let entries) = section else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "actions", message: "expected an object"))
            return [:]
        }
        var result: [String: ConfigCommandAction] = [:]
        for (name, value) in entries {
            let path = "actions.\(name)"
            guard case .object(let fields) = value else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an object"))
                continue
            }
            let type = trimmed(fields["type"]) ?? (fields["agent"] != nil ? "agent" : "command")
            guard let command = commandText(type: type, fields: fields, path: path, diagnostics: &diagnostics) else { continue }
            let tooltip = trimmed(fields["tooltip"])
            result[name] = ConfigCommandAction(
                name: name,
                title: trimmed(fields["title"]) ?? tooltip ?? name,
                tooltip: tooltip,
                icon: icon(fields["icon"], configDirectory: configDirectory),
                command: command,
                target: target(fields["target"], path: path, diagnostics: &diagnostics)
            )
        }
        return result
    }

    /// The shell text for a `command` or `agent` entry, or nil (reported).
    nonisolated static func commandText(type: String, fields: [String: JSONValue], path: String,
                                        diagnostics: inout [SettingsDiagnostic]) -> String? {
        switch type {
        case "command":
            guard let command = trimmed(fields["command"]) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).command", message: "command actions need a command"))
                return nil
            }
            return command
        case "agent":
            guard let agent = trimmed(fields["agent"]), !agent.contains(where: \.isWhitespace) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).agent",
                                                      message: "agent must be one command name; put flags in args"))
                return nil
            }
            let name = agentCommand(agent)
            let args = trimmed(fields["args"])
            return args.map { "\(name) \($0)" } ?? name
        default:
            diagnostics.append(SettingsDiagnostic(kind: .unknownAction, path: "\(path).type",
                                                  message: "type '\(type)' is not supported in cmux-next yet"))
            return nil
        }
    }

    /// Known agent spellings map to their CLI; any other name is the CLI.
    nonisolated static func agentCommand(_ agent: String) -> String {
        switch agent {
        case "claude", "claudeCode", "claude-code": "claude"
        case "opencode", "openCode", "open-code": "opencode"
        default: agent
        }
    }

    nonisolated static func target(_ value: JSONValue?, path: String,
                                   diagnostics: inout [SettingsDiagnostic]) -> ConfigCommandAction.Target {
        guard let value else { return .newTabInCurrentPane }
        if let raw = value.stringValue, let target = ConfigCommandAction.Target(rawValue: raw) { return target }
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).target",
                                              message: "expected newTabInCurrentPane or currentTerminal"))
        return .newTabInCurrentPane
    }

    /// `"name"`, `{type: symbol, name}`, or `{type: image, path}`. Emoji
    /// icons fall back to the action's default glyph.
    nonisolated static func icon(_ value: JSONValue?, configDirectory: URL) -> ConfigIcon? {
        guard let value else { return nil }
        if let name = trimmed(value) { return .symbol(name) }
        guard case .object(let fields) = value else { return nil }
        switch trimmed(fields["type"]) {
        case "symbol", "sfSymbol", "systemImage":
            return trimmed(fields["name"]).map(ConfigIcon.symbol)
        case "image", "file":
            guard let path = trimmed(fields["path"]) else { return nil }
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(filePath: expanded)
                : configDirectory.appending(path: expanded)
            return .image(url.standardizedFileURL)
        default:
            return nil
        }
    }

    nonisolated static func trimmed(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
