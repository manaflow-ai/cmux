import Foundation

/// Additional checks for config sections decoded by `CmuxConfigFile` but not
/// represented in the action/command shape validator. This stays Foundation-
/// only so the standalone CLI and the app report the same runtime failures.
extension CmuxConfigValidator {
    func validateRuntimeOnlySections(in root: Object) -> [CmuxConfigValidationIssue] {
        var issues = [CmuxConfigValidationIssue]()
        validateSurfaceButtons(root["surfaceTabBarButtons"], path: "surfaceTabBarButtons", into: &issues)
        validateUI(root["ui"], into: &issues)
        if let rawNewWorkspaceCommand = root["newWorkspaceCommand"] {
            requireNonBlankString(rawNewWorkspaceCommand, path: "newWorkspaceCommand", into: &issues)
        }
        return issues
    }

    private func validateUI(
        _ rawUI: Any?,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let rawUI else { return }
        guard let ui = rawUI as? Object else {
            issues.append(issue("ui", "must be a JSON object"))
            return
        }

        if let rawNewWorkspace = ui["newWorkspace"] {
            validateButtonPlacement(rawNewWorkspace, path: "ui.newWorkspace", into: &issues)
        }
        if let rawSurfaceTabBar = ui["surfaceTabBar"] {
            guard let surfaceTabBar = rawSurfaceTabBar as? Object else {
                issues.append(issue("ui.surfaceTabBar", "must be a JSON object"))
                return
            }
            validateSurfaceButtons(
                surfaceTabBar["buttons"],
                path: "ui.surfaceTabBar.buttons",
                into: &issues
            )
        }
    }

    private func validateButtonPlacement(
        _ rawPlacement: Any,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let placement = rawPlacement as? Object else {
            issues.append(issue(path, "must be a JSON object"))
            return
        }
        validateOptionalString(placement["action"], path: path + ".action", into: &issues)
        validateOptionalString(placement["tooltip"], path: path + ".tooltip", into: &issues)
        validateIcon(placement["icon"], path: path + ".icon", into: &issues)
        let allowedMenuSectionOrders = [
            "customFirst",
            "workspaceFirst",
            "newWorkspaceFirst",
            "cloudFirst",
            "cloudVMFirst",
        ]
        let allowedMenuSectionOrdersDescription = allowedMenuSectionOrders.joined(separator: ", ")
        if let rawOrder = placement["menuSectionOrder"] ?? placement["sectionOrder"],
           let order = rawOrder as? String {
            let normalized = order.trimmingCharacters(in: .whitespacesAndNewlines)
            if !allowedMenuSectionOrders.contains(normalized) {
                issues.append(issue(
                    path + ".menuSectionOrder",
                    "must be one of \(allowedMenuSectionOrdersDescription)"
                ))
            }
        } else if placement["menuSectionOrder"] != nil || placement["sectionOrder"] != nil {
            issues.append(issue(
                path + ".menuSectionOrder",
                "must be one of \(allowedMenuSectionOrdersDescription)"
            ))
        }
        if let rawContextMenu = placement["contextMenu"] ?? placement["rightClick"] {
            guard let contextMenu = rawContextMenu as? [Any] else {
                issues.append(issue(path + ".contextMenu", "must be an array"))
                return
            }
            for (index, item) in contextMenu.enumerated() {
                validateContextMenuItem(item, path: path + ".contextMenu[\(index)]", into: &issues)
            }
        }
    }

    private func validateContextMenuItem(
        _ rawItem: Any,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        if let value = rawItem as? String {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(issue(path, "context-menu action must not be blank"))
            }
            return
        }
        guard let item = rawItem as? Object else {
            issues.append(issue(path, "must be a string or JSON object"))
            return
        }
        if let type = item["type"] as? String,
           type.trimmingCharacters(in: .whitespacesAndNewlines) == "separator" {
            return
        }
        requireNonBlankString(item["action"], path: path + ".action", into: &issues)
        validateOptionalString(item["title"], path: path + ".title", into: &issues)
        validateOptionalString(item["tooltip"], path: path + ".tooltip", into: &issues)
        validateIcon(item["icon"], path: path + ".icon", into: &issues)
    }

    private func validateSurfaceButtons(
        _ rawButtons: Any?,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let rawButtons else { return }
        guard let buttons = rawButtons as? [Any] else {
            issues.append(issue(path, "must be an array"))
            return
        }
        for (index, rawButton) in buttons.enumerated() {
            validateSurfaceButton(rawButton, path: path + "[\(index)]", into: &issues)
        }
    }

    private func validateSurfaceButton(
        _ rawButton: Any,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        if let value = rawButton as? String {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(issue(path, "surface tab bar button action must not be blank"))
            }
            return
        }
        guard let button = rawButton as? Object else {
            issues.append(issue(path, "must be a string or JSON object"))
            return
        }

        if button["id"] != nil {
            requireNonBlankString(button["id"], path: path + ".id", into: &issues)
        }
        validateOptionalString(button["title"], path: path + ".title", into: &issues)
        validateOptionalString(button["tooltip"], path: path + ".tooltip", into: &issues)
        validateIcon(button["icon"], path: path + ".icon", into: &issues)
        if let confirm = button["confirm"], !(confirm is Bool) {
            issues.append(issue(path + ".confirm", "must be a boolean"))
        }
        if let target = button["target"] {
            if let value = target as? String,
               ["currentTerminal", "newTabInCurrentPane"].contains(value) {
                // valid
            } else {
                issues.append(issue(path + ".target", "must be currentTerminal or newTabInCurrentPane"))
            }
        }

        let forms = ["action", "builtin", "command", "agent", "type"].filter { button[$0] != nil }
        if forms.count > 1 {
            issues.append(issue(path, "entries must define only one action form"))
            return
        }

        if let rawType = button["type"] {
            guard let type = rawType as? String else {
                issues.append(issue(path + ".type", "must be a non-empty string"))
                return
            }
            let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedType.isEmpty else {
                issues.append(issue(path + ".type", "must be a non-empty string"))
                return
            }
            switch normalizedType {
            case "workspaceCommand":
                validateWorkspaceCommandFields(button, path: path, into: &issues)
            case "workspace":
                guard let workspace = button["workspace"] as? Object else {
                    issues.append(issue(path + ".workspace", "must be a JSON object"))
                    return
                }
                validateWorkspace(workspace, path: path + ".workspace", into: &issues)
                validateRestart(button["restart"], path: path + ".restart", into: &issues)
            default:
                issues.append(issue(path + ".type", "unknown surface tab bar button type '\(normalizedType)'"))
            }
            return
        }

        if let rawAction = button["action"] {
            requireNonBlankString(rawAction, path: path + ".action", into: &issues)
        } else if let rawBuiltin = button["builtin"] {
            requireNonBlankString(rawBuiltin, path: path + ".builtin", into: &issues)
            if let builtin = rawBuiltin as? String,
               canonicalBuiltInID(builtin.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                issues.append(issue(path + ".builtin", "unknown built-in surface tab bar action"))
            }
        } else if let rawCommand = button["command"] {
            requireNonBlankString(rawCommand, path: path + ".command", into: &issues)
        } else if let rawAgent = button["agent"] {
            validateAgent(rawAgent, args: button["args"], path: path, into: &issues)
        } else if let rawID = button["id"] as? String,
                  canonicalBuiltInID(rawID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            // An explicit built-in id is a supported shorthand.
        } else {
            issues.append(issue(path, "entries must define an action, builtin, command, agent, or type"))
        }
    }

    private func validateWorkspaceCommandFields(
        _ button: Object,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        var found = false
        for key in ["commandName", "name"] {
            guard button[key] != nil else { continue }
            requireNonBlankString(button[key], path: path + "." + key, into: &issues)
            found = true
        }
        if let command = button["command"] {
            requireNonBlankString(command, path: path + ".command", into: &issues)
            found = true
        }
        if !found {
            issues.append(issue(path, "workspaceCommand entries require commandName"))
        }
    }

    private func validateAgent(
        _ rawAgent: Any,
        args rawArgs: Any?,
        path: String,
        into issues: inout [CmuxConfigValidationIssue]
    ) {
        guard let agent = rawAgent as? String,
              !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues.append(issue(path + ".agent", "must be a non-empty command name"))
            return
        }
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            issues.append(issue(path + ".agent", "must be a single command name; put flags in 'args'"))
        }
        validateOptionalString(rawArgs, path: path + ".args", into: &issues)
    }
}
