import Foundation

struct SidebarPromptLauncherWorkspaceMetadata: Equatable {
    enum Phase: String, Equatable {
        case attached
        case ready
    }

    var workspace: String?
    var title: String?
    var description: String?
    var color: String?
    var slot: String?
    var phase: Phase?
}
enum SidebarPromptLauncherTemplateRenderer {
    static func renderCommand(
        config: CmuxPromptLauncherDefinition,
        targetID: String,
        providerID: String,
        repositoryID: String? = nil,
        prompt: String
    ) -> String? {
        guard let target = config.targets.first(where: { $0.id == targetID }),
              let provider = config.providers.first(where: { $0.id == providerID }) else {
            return nil
        }
        let repository: CmuxPromptLauncherChoice?
        if config.repositories.isEmpty {
            repository = nil
        } else {
            guard let repositoryID,
                  let configuredRepository = config.repositories.first(where: { $0.id == repositoryID }) else {
                return nil
            }
            repository = configuredRepository
        }
        var values = [
            "prompt": shellQuote(prompt),
            "target.id": shellQuote(target.id),
            "target.title": shellQuote(target.title),
            "target.args": shellArguments(target.args),
            "environment.id": shellQuote(target.id),
            "environment.title": shellQuote(target.title),
            "environment.args": shellArguments(target.args),
            "environment.arguments": shellArguments(target.args),
            "provider.id": shellQuote(provider.id),
            "provider.title": shellQuote(provider.title),
            "provider.args": shellArguments(provider.args),
            "provider.arguments": shellArguments(provider.args),
        ]
        if let repository {
            values["repository.id"] = shellQuote(repository.id)
            values["repository.title"] = shellQuote(repository.title)
            values["repository.args"] = shellArguments(repository.args)
            values["repository.arguments"] = shellArguments(repository.args)
        }
        return renderTemplate(
            config.command,
            values: values
        )
    }

    @MainActor
    static func renderCloseHook(
        config: CmuxPromptLauncherDefinition,
        workspace: Workspace
    ) -> String? {
        renderWorkspaceHook(config.closeHook, workspace: workspace)
    }

    @MainActor
    static func renderRestartHook(
        config: CmuxPromptLauncherDefinition,
        workspace: Workspace
    ) -> String? {
        renderWorkspaceHook(config.restartHook, workspace: workspace)
    }

    @MainActor
    private static func renderWorkspaceHook(_ hook: String?, workspace: Workspace) -> String? {
        guard let hook else { return nil }
        let slot = workspace.promptLauncherSlot ?? defaultSlot(fromWorkspaceTitle: workspace.title)
        var values: [String: String] = [
            "workspace.id": shellQuote(workspace.id.uuidString),
            "workspace.title": shellQuote(workspace.title),
        ]
        if let description = workspace.customDescription {
            values["workspace.description"] = shellQuote(description)
        }
        if let color = workspace.customColor {
            values["workspace.color"] = shellQuote(color)
        }
        if let slot {
            values["workspace.slot"] = shellQuote(slot)
        }
        return renderTemplate(
            hook,
            values: values
        )
    }

    static func metadata(from line: String, prefix: String?) -> SidebarPromptLauncherWorkspaceMetadata? {
        guard let prefix, line.hasPrefix(prefix) else { return nil }
        let rawJSON = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return SidebarPromptLauncherWorkspaceMetadata(
            workspace: firstString(in: object, keys: [
                "workspace", "workspaceRef", "workspace_ref", "workspaceId", "workspace_id"
            ]),
            title: firstString(in: object, keys: ["title", "name"]),
            description: firstString(in: object, keys: ["description"]),
            color: firstString(in: object, keys: ["color", "workspaceColor", "workspace_color"]),
            slot: firstString(in: object, keys: ["slot", "workspaceSlot", "workspace_slot"]),
            phase: firstString(in: object, keys: ["phase"]).flatMap(
                SidebarPromptLauncherWorkspaceMetadata.Phase.init(rawValue:)
            )
        )
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func stripAnsi(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\x1B\[[0-9;]*[A-Za-z]|\r"#) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func isCompletionLine(_ line: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            !pattern.isEmpty && line.contains(pattern)
        }
    }

    static func defaultSlot(fromWorkspaceTitle title: String) -> String? {
        if let number = SessionCardSnapshot.indexedWorktreeNumber(in: title) {
            return "wk\(number)"
        }
        guard let regex = try? NSRegularExpression(pattern: #"\[(?:wk)?([0-9]+)\]"#) else {
            return nil
        }
        let range = NSRange(title.startIndex..., in: title)
        guard let match = regex.firstMatch(in: title, range: range),
              match.numberOfRanges > 1,
              let digitRange = Range(match.range(at: 1), in: title) else {
            return nil
        }
        return "wk\(title[digitRange])"
    }

    private static func shellArguments(_ values: [String]) -> String {
        values.map(shellQuote).joined(separator: " ")
    }

    private static func renderTemplate(_ template: String, values: [String: String]) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.]+)\s*\}\}"#) else {
            return template
        }
        var rendered = template
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: rendered),
                  let keyRange = Range(match.range(at: 1), in: template) else {
                return nil
            }
            let key = String(template[keyRange])
            guard let replacement = values[key] else {
                return nil
            }
            rendered.replaceSubrange(fullRange, with: replacement)
        }
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rendered
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
