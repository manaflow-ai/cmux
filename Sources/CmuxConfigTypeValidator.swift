import Foundation

/// Validates the JSON shapes consumed by cmux's configuration decoder.
///
/// This validator intentionally works on Foundation JSON values so the app
/// and the standalone CLI can share the same command-entry contract without
/// importing the AppKit-backed config store into the CLI target.
struct CmuxConfigTypeValidator: Sendable {
    private let workspaceColorNames: Set<String>

    init(workspaceColorNames: Set<String>? = nil) {
        let names = workspaceColorNames ?? Self.workspaceColorNames(from: .standard)
        self.workspaceColorNames = Set(names.map { $0.lowercased() })
    }

    static let builtInWorkspaceColorNames = [
        "Red", "Crimson", "Orange", "Amber", "Olive", "Green", "Teal", "Aqua",
        "Blue", "Navy", "Indigo", "Purple", "Magenta", "Rose", "Brown", "Charcoal",
    ]

    static func workspaceColorNames(from defaults: UserDefaults) -> Set<String> {
        var names = Set(builtInWorkspaceColorNames)
        if let configured = defaults.dictionary(forKey: "workspaceTabColor.colors") {
            names.formUnion(configured.keys)
        }
        if let overrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") {
            names.formUnion(overrides.keys)
        }
        return names
    }

    func issues(in object: Any) -> [CmuxConfigTypeIssue] {
        guard let root = object as? [String: Any] else {
            return [issue(path: "root", key: "invalidField", arguments: ["an object"])]
        }
        guard let rawCommands = root["commands"], !isNull(rawCommands) else {
            return []
        }
        guard let commands = rawCommands as? [Any] else {
            return [issue(path: "commands", key: "invalidField", arguments: ["an array"])]
        }

        var issues: [CmuxConfigTypeIssue] = []
        for (index, rawEntry) in commands.enumerated() {
            let path = "commands[\(index)]"
            guard let entry = rawEntry as? [String: Any] else {
                issues.append(issue(path: path, key: "invalidField", arguments: ["an object"]))
                continue
            }
            validateEntry(entry, path: path, issues: &issues)
        }
        return issues
    }

    func issues(in data: Data) throws -> [CmuxConfigTypeIssue] {
        let object = try JSONSerialization.jsonObject(with: data)
        return issues(in: object)
    }

    private func validateEntry(
        _ entry: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let name = entry["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues.append(issue(path: "\(path).name", key: "invalidField", arguments: ["a non-blank string"]))
            return
        }

        validateCommonFields(entry, path: path, issues: &issues)

        if let rawCommand = entry["command"], !isNull(rawCommand) {
            guard let command = rawCommand as? String,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues.append(issue(path: "\(path).command", key: "invalidField", arguments: ["a non-blank string"]))
                return
            }
            // `command` is the discriminator. A mixed entry may carry stale
            // layout metadata; the runtime decoder deliberately ignores it.
            _ = command
            return
        }

        if let rawWorkspace = entry["workspace"], !isNull(rawWorkspace) {
            guard let workspace = rawWorkspace as? [String: Any] else {
                issues.append(issue(path: "\(path).workspace", key: "invalidField", arguments: ["an object"]))
                return
            }
            validateWorkspace(workspace, path: "\(path).workspace", issues: &issues)
            return
        }

        let flattenedWorkspaceKeys = ["cwd", "color", "env", "setup", "layout"]
        guard flattenedWorkspaceKeys.contains(where: { key in
            guard let value = entry[key] else { return false }
            return !isNull(value)
        }) else {
            issues.append(issue(path: path, key: "missingDefinition", arguments: []))
            return
        }
        validateWorkspace(entry, path: path, issues: &issues)
    }

    private func validateCommonFields(
        _ entry: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        if let value = entry["description"], !isNull(value), !(value is String) {
            issues.append(issue(path: "\(path).description", key: "invalidField", arguments: ["a string"]))
        }
        if let value = entry["keywords"], !isNull(value) {
            if !((value as? [Any])?.allSatisfy({ $0 is String }) ?? false) {
                issues.append(issue(path: "\(path).keywords", key: "invalidField", arguments: ["an array of strings"]))
            }
        }
        if let value = entry["restart"], !isNull(value) {
            let allowed = ["new", "recreate", "ignore", "confirm"]
            if !((value as? String).map(allowed.contains) ?? false) {
                issues.append(issue(path: "\(path).restart", key: "invalidValue", arguments: []))
            }
        }
        if let value = entry["confirm"], !isNull(value), !(value is Bool) {
            issues.append(issue(path: "\(path).confirm", key: "invalidField", arguments: ["a boolean"]))
        }
    }

    private func validateWorkspace(
        _ workspace: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        for key in ["name", "cwd", "setup"] {
            if let value = workspace[key], !isNull(value), !(value is String) {
                issues.append(issue(path: "\(path).\(key)", key: "invalidField", arguments: ["a string"]))
            }
        }
        if let value = workspace["color"], !isNull(value) {
            guard let color = value as? String,
                  !color.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues.append(issue(path: "\(path).color", key: "invalidField", arguments: ["a non-blank string"]))
                return
            }
            if !isSixDigitHexColor(color), !workspaceColorNames.contains(color.lowercased()) {
                issues.append(issue(path: "\(path).color", key: "invalidValue", arguments: []))
            }
        }
        if let value = workspace["env"], !isNull(value) {
            if !((value as? [String: Any])?.values.allSatisfy({ $0 is String }) ?? false) {
                issues.append(issue(path: "\(path).env", key: "invalidField", arguments: ["an object of strings"]))
            }
        }
        if let value = workspace["layout"], !isNull(value) {
            guard let layout = value as? [String: Any] else {
                issues.append(issue(path: "\(path).layout", key: "invalidField", arguments: ["an object"]))
                return
            }
            validateLayout(layout, path: "\(path).layout", issues: &issues)
        }
    }

    private func validateLayout(
        _ node: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        let hasPane = node.keys.contains("pane")
        let hasDirection = node.keys.contains("direction")
        guard !(hasPane && hasDirection) else {
            issues.append(issue(path: path, key: "invalidValue", arguments: []))
            return
        }

        if hasPane {
            guard let rawPane = node["pane"] as? [String: Any] else {
                issues.append(issue(path: "\(path).pane", key: "invalidField", arguments: ["an object"]))
                return
            }
            validatePane(rawPane, path: "\(path).pane", issues: &issues)
            return
        }

        guard hasDirection else {
            issues.append(issue(path: path, key: "invalidValue", arguments: []))
            return
        }
        guard let direction = node["direction"] as? String,
              direction == "horizontal" || direction == "vertical" else {
            issues.append(issue(path: "\(path).direction", key: "invalidValue", arguments: []))
            return
        }
        if let value = node["split"], !isNull(value), !isJSONNumber(value) {
            issues.append(issue(path: "\(path).split", key: "invalidField", arguments: ["a number"]))
        }
        guard let rawChildren = node["children"] as? [Any] else {
            issues.append(issue(path: "\(path).children", key: "invalidField", arguments: ["an array"]))
            return
        }
        let allowsLegacySingleChild = !path.contains(".workspace")
        guard rawChildren.count == 2 || (allowsLegacySingleChild && rawChildren.count == 1) else {
            issues.append(issue(
                path: "\(path).children",
                key: "invalidCount",
                arguments: [allowsLegacySingleChild ? "1 or 2" : "2"]
            ))
            return
        }
        for (index, rawChild) in rawChildren.enumerated() {
            guard let child = rawChild as? [String: Any] else {
                issues.append(issue(path: "\(path).children[\(index)]", key: "invalidField", arguments: ["an object"]))
                continue
            }
            validateLayout(child, path: "\(path).children[\(index)]", issues: &issues)
        }
    }

    private func validatePane(
        _ pane: [String: Any],
        path: String,
        issues: inout [CmuxConfigTypeIssue]
    ) {
        guard let rawSurfaces = pane["surfaces"] as? [Any] else {
            issues.append(issue(path: "\(path).surfaces", key: "invalidField", arguments: ["an array"]))
            return
        }
        guard !rawSurfaces.isEmpty else {
            issues.append(issue(path: "\(path).surfaces", key: "invalidCount", arguments: ["at least 1"]))
            return
        }
        for (index, rawSurface) in rawSurfaces.enumerated() {
            let surfacePath = "\(path).surfaces[\(index)]"
            guard let surface = rawSurface as? [String: Any] else {
                issues.append(issue(path: surfacePath, key: "invalidField", arguments: ["an object"]))
                continue
            }
            guard let type = surface["type"] as? String,
                  ["terminal", "browser", "project"].contains(type) else {
                issues.append(issue(path: "\(surfacePath).type", key: "invalidValue", arguments: []))
                continue
            }
            for key in ["name", "command", "cwd", "url"] {
                if let value = surface[key], !isNull(value), !(value is String) {
                    issues.append(issue(path: "\(surfacePath).\(key)", key: "invalidField", arguments: ["a string"]))
                }
            }
            if let value = surface["env"], !isNull(value) {
                guard let environment = value as? [String: Any],
                      environment.values.allSatisfy({ $0 is String }) else {
                    issues.append(issue(path: "\(surfacePath).env", key: "invalidField", arguments: ["an object of strings"]))
                    continue
                }
            }
            if let value = surface["focus"], !isNull(value), !(value is Bool) {
                issues.append(issue(path: "\(surfacePath).focus", key: "invalidField", arguments: ["a boolean"]))
            }
        }
    }

    private func isSixDigitHexColor(_ value: String) -> Bool {
        let body = value.hasPrefix("#") ? value.dropFirst() : value[...]
        let scalars = Array(body.unicodeScalars)
        guard scalars.count == 6 else { return false }
        return scalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 70)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private func isJSONNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        return type != "c" && type != "B"
    }

    private func issue(path: String, key: String, arguments: [String]) -> CmuxConfigTypeIssue {
        let localized: String
        switch key {
        case "missingDefinition":
            localized = String(
                localized: "config.validation.missingDefinition",
                defaultValue: "must define either 'command' or a workspace layout"
            )
        case "invalidValue":
            localized = String(
                localized: "config.validation.invalidValue",
                defaultValue: "has an invalid value"
            )
        case "invalidCount":
            localized = String(
                localized: "config.validation.invalidCount",
                defaultValue: "must contain %@ item(s)"
            )
        default:
            localized = String(
                localized: "config.validation.invalidField",
                defaultValue: "must be %@"
            )
        }
        let cvarArguments: [CVarArg] = arguments.map { $0 as NSString }
        return CmuxConfigTypeIssue(
            path: path,
            message: String(format: localized, arguments: cvarArguments)
        )
    }
}
