import Foundation

/// A structural config error that can be reported without importing the app's
/// AppKit-backed config model. The CLI and the published JSON Schema use the
/// same shape checks for the sections that contain executable actions.
struct CmuxConfigValidationIssue: Equatable, Sendable, CustomStringConvertible {
    let path: String
    let message: String

    var description: String {
        path + ": " + message
    }
}

struct CmuxConfigValidator: Sendable {
    private typealias Object = [String: Any]

    func validate(data: Data) -> [CmuxConfigValidationIssue] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return [CmuxConfigValidationIssue(path: "$", message: "config must be valid JSON")]
        }
        return validate(jsonObject: object)
    }

    func validate(jsonObject: Any) -> [CmuxConfigValidationIssue] {
        guard let root = jsonObject as? Object else {
            return [CmuxConfigValidationIssue(path: "$", message: "top-level value must be a JSON object")]
        }

        var issues = [CmuxConfigValidationIssue]()
        if let rawActions = root["actions"] {
            guard let actions = rawActions as? Object else {
                issues.append(issue("actions", "must be a JSON object"))
                return issues
            }
            for actionID in actions.keys.sorted() {
                validateAction(actions[actionID], path: "actions.\(actionID)", into: &issues)
            }
        }

        if let rawCommands = root["commands"] {
            guard let commands = rawCommands as? [Any] else {
                issues.append(issue("commands", "must be a JSON array"))
                return issues
            }
            for (index, rawCommand) in commands.enumerated() {
                validateCommand(rawCommand, path: "commands[\(index)]", into: &issues)
            }
        }
        return issues
    }

    private func validateAction(
        _ rawAction: Any?,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let action = rawAction as? Object else {
            issues.append(issue(path, "must be a JSON object"))
            return
        }
        validateCommonActionFields(action, path: path, into: &issues)

        let type: String?
        if let rawType = action["type"] {
            guard let value = rawType as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues.append(issue(path + ".type", "must be a non-empty string"))
                return
            }
            type = value
        } else if action["agent"] != nil {
            type = "agent"
        } else if action["builtin"] != nil {
            type = "builtin"
        } else if action["workspace"] != nil {
            type = "workspace"
        } else if action["command"] != nil {
            type = "command"
        } else {
            type = nil
        }

        switch type {
        case "builtin":
            requireNonBlankString(action["builtin"], path: path + ".builtin", into: &issues)
        case "command":
            requireNonBlankString(action["command"], path: path + ".command", into: &issues)
        case "agent":
            guard let agent = action["agent"] as? String,
                  !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues.append(issue(path + ".agent", "must be a non-empty command name"))
                break
            }
            if agent.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                issues.append(issue(path + ".agent", "must be a single command name; put flags in 'args'"))
            }
            validateOptionalString(action["args"], path: path + ".args", into: &issues)
        case "workspaceCommand":
            let commandName = ["commandName", "name", "command"].compactMap { key -> String? in
                guard let value = action[key] as? String else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }.first
            if commandName == nil {
                issues.append(issue(path, "workspaceCommand actions require commandName"))
            }
        case "workspace":
            guard let workspace = action["workspace"] as? Object else {
                issues.append(issue(path + ".workspace", "must be a JSON object"))
                break
            }
            validateWorkspace(workspace, path: path + ".workspace", into: &issues)
            validateRestart(action["restart"], path: path + ".restart", into: &issues)
        case nil:
            break
        default:
            issues.append(issue(path + ".type", "unknown action type '\(type ?? "")'"))
        }
    }

    private func validateCommonActionFields(
        _ action: Object,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        for key in ["title", "subtitle", "description", "tooltip"] {
            validateOptionalString(action[key], path: path + "." + key, into: &issues)
        }
        if let keywords = action["keywords"] {
            if !((keywords as? [Any])?.allSatisfy({ $0 is String }) ?? false) {
                issues.append(issue(path + ".keywords", "must be an array of strings"))
            }
        }
        for key in ["palette", "confirm", "newWorkspaceMenu"] {
            if let value = action[key], !(value is Bool) {
                issues.append(issue(path + "." + key, "must be a boolean"))
            }
        }
        if let target = action["target"] {
            guard let value = target as? String,
                  ["currentTerminal", "newTabInCurrentPane"].contains(value) else {
                issues.append(issue(path + ".target", "must be currentTerminal or newTabInCurrentPane"))
                return
            }
        }
        validateShortcut(action["shortcut"], path: path + ".shortcut", into: &issues)
        validateIcon(action["icon"], path: path + ".icon", into: &issues)
    }

    private func validateCommand(
        _ rawCommand: Any,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let command = rawCommand as? Object else {
            issues.append(issue(path, "must be a JSON object"))
            return
        }
        requireNonBlankString(command["name"], path: path + ".name", into: &issues)
        validateOptionalString(command["description"], path: path + ".description", into: &issues)
        if let keywords = command["keywords"] {
            if !((keywords as? [Any])?.allSatisfy({ $0 is String }) ?? false) {
                issues.append(issue(path + ".keywords", "must be an array of strings"))
            }
        }
        validateRestart(command["restart"], path: path + ".restart", into: &issues)
        if let confirm = command["confirm"], !(confirm is Bool) {
            issues.append(issue(path + ".confirm", "must be a boolean"))
        }

        let hasWorkspace = command["workspace"] != nil
        let hasShellCommand = command["command"] != nil
        if hasWorkspace == hasShellCommand {
            issues.append(issue(path, "must define exactly one of 'workspace' or 'command'"))
        }
        if hasShellCommand {
            requireNonBlankString(command["command"], path: path + ".command", into: &issues)
        }
        if let workspace = command["workspace"] as? Object {
            validateWorkspace(workspace, path: path + ".workspace", into: &issues)
        } else if hasWorkspace {
            issues.append(issue(path + ".workspace", "must be a JSON object"))
        }
    }

    private func validateWorkspace(
        _ workspace: Object,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        for key in ["name", "cwd", "color", "setup"] {
            validateOptionalString(workspace[key], path: path + "." + key, into: &issues)
        }
        if let env = workspace["env"] {
            if !((env as? Object)?.values.allSatisfy({ $0 is String }) ?? false) {
                issues.append(issue(path + ".env", "must be an object whose values are strings"))
            }
        }
        if let layout = workspace["layout"] {
            validateLayout(layout, path: path + ".layout", depth: 0, into: &issues)
        }
    }

    private func validateLayout(
        _ rawLayout: Any,
        path: String,
        depth: Int,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard depth < 100 else {
            issues.append(issue(path, "layout nesting is too deep"))
            return
        }
        guard let layout = rawLayout as? Object else {
            issues.append(issue(path, "must be a JSON object"))
            return
        }
        let hasPane = layout["pane"] != nil
        let hasDirection = layout["direction"] != nil
        if hasPane && hasDirection {
            issues.append(issue(path, "must not contain both 'pane' and 'direction' keys"))
            return
        }
        if hasPane {
            guard let pane = layout["pane"] as? Object else {
                issues.append(issue(path + ".pane", "must be a JSON object"))
                return
            }
            guard let rawSurfaces = pane["surfaces"] as? [Any] else {
                issues.append(issue(path + ".pane.surfaces", "must be an array"))
                return
            }
            if rawSurfaces.isEmpty {
                issues.append(issue(path + ".pane.surfaces", "must contain at least one surface"))
            }
            for (index, surface) in rawSurfaces.enumerated() {
                validateSurface(surface, path: path + ".pane.surfaces[\(index)]", into: &issues)
            }
            return
        }
        guard hasDirection else {
            issues.append(issue(path, "must contain either a 'pane' key or a 'direction' key"))
            return
        }
        guard let direction = layout["direction"] as? String,
              ["horizontal", "vertical"].contains(direction) else {
            issues.append(issue(path + ".direction", "must be horizontal or vertical"))
            return
        }
        if let split = layout["split"], !isNumber(split) {
            issues.append(issue(path + ".split", "must be a number"))
        }
        guard let children = layout["children"] as? [Any] else {
            issues.append(issue(path + ".children", "must be an array"))
            return
        }
        guard children.count == 2 else {
            issues.append(issue(path + ".children", "Split node requires exactly 2 children, got \(children.count)"))
            return
        }
        for (index, child) in children.enumerated() {
            validateLayout(child, path: path + ".children[\(index)]", depth: depth + 1, into: &issues)
        }
    }

    private func validateSurface(
        _ rawSurface: Any,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let surface = rawSurface as? Object else {
            issues.append(issue(path, "must be a JSON object"))
            return
        }
        guard let type = surface["type"] as? String,
              ["terminal", "browser", "project"].contains(type) else {
            issues.append(issue(path + ".type", "must be terminal, browser, or project"))
            return
        }
        for key in ["name", "command", "cwd", "url"] {
            validateOptionalString(surface[key], path: path + "." + key, into: &issues)
        }
        if let env = surface["env"],
           !((env as? Object)?.values.allSatisfy { $0 is String } ?? false) {
            issues.append(issue(path + ".env", "must be an object whose values are strings"))
        }
        if let focus = surface["focus"], !(focus is Bool) {
            issues.append(issue(path + ".focus", "must be a boolean"))
        }
    }

    private func validateRestart(
        _ rawValue: Any?,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let rawValue else { return }
        guard let value = rawValue as? String,
              ["new", "recreate", "ignore", "confirm"].contains(value) else {
            issues.append(issue(path, "must be new, recreate, ignore, or confirm"))
            return
        }
    }

    private func validateIcon(
        _ rawIcon: Any?,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let rawIcon else { return }
        guard let icon = rawIcon as? Object else {
            issues.append(issue(path, "must be an object"))
            return
        }
        guard let type = icon["type"] as? String else {
            issues.append(issue(path + ".type", "must be a string"))
            return
        }
        switch type {
        case "symbol", "sfSymbol", "systemImage":
            requireNonBlankString(icon["name"], path: path + ".name", into: &issues)
        case "emoji":
            requireNonBlankString(icon["value"], path: path + ".value", into: &issues)
            if let scale = icon["scale"] as? NSNumber, isNumber(scale), scale.doubleValue <= 0 {
                issues.append(issue(path + ".scale", "must be a positive number"))
            } else if let scale = icon["scale"], !isNumber(scale) {
                issues.append(issue(path + ".scale", "must be a number"))
            }
        case "image", "file":
            requireNonBlankString(icon["path"], path: path + ".path", into: &issues)
        default:
            issues.append(issue(path + ".type", "unknown icon type '\(type)'"))
        }
    }

    private func validateShortcut(
        _ rawShortcut: Any?,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let rawShortcut else { return }
        if rawShortcut is String { return }
        guard let strokes = rawShortcut as? [Any],
              (1...2).contains(strokes.count),
              strokes.allSatisfy({ $0 is String }) else {
            issues.append(issue(path, "must be a string or an array of one or two strings"))
            return
        }
    }

    private func requireNonBlankString(
        _ rawValue: Any?,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let value = rawValue as? String else {
            issues.append(issue(path, "must be a non-empty string"))
            return
        }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(issue(path, "must be a non-empty string"))
        }
    }

    private func validateOptionalString(
        _ rawValue: Any?,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        if let rawValue, !(rawValue is String) {
            issues.append(issue(path, "must be a string"))
        }
    }

    private func isNumber(_ value: Any) -> Bool {
        value is NSNumber && !(value is Bool)
    }

    private func issue(_ path: String, _ message: String) -> CmuxConfigValidationIssue {
        CmuxConfigValidationIssue(path: path, message: message)
    }
}
