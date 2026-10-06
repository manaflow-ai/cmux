public import Foundation

/// Parses `ui.surfaceTabBar.buttons` (or the legacy root
/// `surfaceTabBarButtons`) into buttons that each run one registry action.
///
/// Entry forms, as in the old app: a string identifier; or an object with
/// one of `action` (identifier), `builtin`, `command`, `agent` (+ `args`),
/// plus optional `id`, `title`, `tooltip`, `icon`, `target`. An identifier
/// resolves as a cmux.json action, then a built-in (`cmux.splitRight`),
/// then a registry action ID (the App drops IDs the registry lacks).
public struct SurfaceTabBarParser {
    public init() {}
    public struct Result: Sendable, Hashable {
        public var tabBar: SurfaceTabBarConfig
        /// Every command action: `actions.<name>` plus inline command buttons.
        public var actions: [ConfigCommandAction]
        public var diagnostics: [SettingsDiagnostic]
    }

    /// The diagnostic for a set `ui.surfaceTabBar.buttons` (or legacy
    /// `surfaceTabBarButtons`): the trailing buttons were removed, so the
    /// list draws nothing. Its inline command entries stay palette actions.
    public nonisolated static let removedMessage = "ignored: the tab bar buttons were removed"

    public nonisolated static func parse(_ root: JSONValue, configDirectory: URL) -> Result {
        var diagnostics: [SettingsDiagnostic] = []
        var actions = ConfigActionParser.parseActions(root, configDirectory: configDirectory, diagnostics: &diagnostics)

        let located: (value: JSONValue, path: String)? = if let value = root.value(at: ["ui", "surfaceTabBar", "buttons"]) {
            (value, "ui.surfaceTabBar.buttons")
        } else if let value = root["surfaceTabBarButtons"] {
            (value, "surfaceTabBarButtons")
        } else {
            nil
        }
        var tabBar = SurfaceTabBarConfig.defaults
        if let (value, path) = located {
            // TAB-STRIP-TRAILING-BUTTONS-REMOVED: the strip draws no buttons.
            diagnostics.append(SettingsDiagnostic(kind: .removedSetting, path: path, message: removedMessage))
            if case .array(let entries) = value {
                var buttons: [TabBarButtonSpec] = []
                var seen = Set<String>()
                for (index, entry) in entries.enumerated() {
                    let entryPath = "\(path).\(index)"
                    guard let button = resolve(entry, path: entryPath, actions: &actions, configDirectory: configDirectory,
                                               diagnostics: &diagnostics) else { continue }
                    guard seen.insert(button.id).inserted else {
                        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: entryPath, message: "duplicate button id '\(button.id)'"))
                        continue
                    }
                    buttons.append(button)
                }
                tabBar = SurfaceTabBarConfig(buttons: buttons, usesDefaults: false)
            }
        }
        let sortedActions = actions.values.sorted { $0.name < $1.name }
        return Result(tabBar: tabBar, actions: sortedActions, diagnostics: diagnostics)
    }

    nonisolated static func resolve(_ entry: JSONValue, path: String, actions: inout [String: ConfigCommandAction],
                                    configDirectory: URL, diagnostics: inout [SettingsDiagnostic]) -> TabBarButtonSpec? {
        if case .string = entry {
            guard let identifier = ConfigActionParser.trimmed(entry) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "blank button"))
                return nil
            }
            return reference(identifier, id: nil, path: path, actions: actions, diagnostics: &diagnostics)
        }
        guard case .object(let fields) = entry else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected a string or an object"))
            return nil
        }
        let forms = ["action", "builtin", "command", "agent", "type"].filter { fields[$0] != nil }
        guard forms.count <= 1 else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "define only one of \(forms.joined(separator: ", "))"))
            return nil
        }
        let explicitID = ConfigActionParser.trimmed(fields["id"])
        var button: TabBarButtonSpec?
        switch forms.first {
        case "action":
            guard let identifier = ConfigActionParser.trimmed(fields["action"]) else { break }
            button = reference(identifier, id: explicitID, path: path, actions: actions, diagnostics: &diagnostics)
        case "builtin":
            guard let identifier = ConfigActionParser.trimmed(fields["builtin"]),
                  BuiltInButtonActions.entry(for: identifier) != nil else {
                diagnostics.append(SettingsDiagnostic(kind: .unknownAction, path: "\(path).builtin", message: "unknown built-in"))
                return nil
            }
            button = reference(identifier, id: explicitID, path: path, actions: actions, diagnostics: &diagnostics)
        case "command", "agent":
            let type = forms.first!
            guard let command = ConfigActionParser.commandText(type: type, fields: fields, path: path, diagnostics: &diagnostics) else {
                return nil
            }
            let name = explicitID ?? "\(type).\(command)"
            let tooltip = ConfigActionParser.trimmed(fields["tooltip"])
            let action = ConfigCommandAction(
                name: name, title: ConfigActionParser.trimmed(fields["title"]) ?? tooltip ?? command, tooltip: tooltip,
                icon: ConfigActionParser.icon(fields["icon"], configDirectory: configDirectory) ?? .symbol("terminal"),
                command: command,
                target: ConfigActionParser.target(fields["target"], path: path, diagnostics: &diagnostics)
            )
            actions[name] = action
            button = TabBarButtonSpec(id: name, actionID: action.actionID, title: action.title, tooltip: action.tooltip, icon: action.icon)
        case "type":
            diagnostics.append(SettingsDiagnostic(kind: .unknownAction, path: "\(path).type",
                                                  message: "workspace buttons are not supported in cmux-next yet"))
            return nil
        default:
            if let explicitID, BuiltInButtonActions.entry(for: explicitID) != nil {
                button = reference(explicitID, id: nil, path: path, actions: actions, diagnostics: &diagnostics)
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "button needs action, builtin, command, or agent"))
                return nil
            }
        }
        guard var button else { return nil }
        if let title = ConfigActionParser.trimmed(fields["title"]) { button.title = title }
        if let tooltip = ConfigActionParser.trimmed(fields["tooltip"]) { button.tooltip = tooltip }
        if let icon = ConfigActionParser.icon(fields["icon"], configDirectory: configDirectory) { button.icon = icon }
        return button
    }

    /// A button for an identifier: config action, built-in, or registry ID.
    nonisolated static func reference(_ identifier: String, id: String?, path: String, actions: [String: ConfigCommandAction],
                                      diagnostics: inout [SettingsDiagnostic]) -> TabBarButtonSpec? {
        if let action = actions[identifier] {
            return TabBarButtonSpec(id: id ?? identifier, actionID: action.actionID, title: action.title,
                                    tooltip: action.tooltip, icon: action.icon)
        }
        if let builtIn = BuiltInButtonActions.entry(for: identifier) {
            return TabBarButtonSpec(id: id ?? builtIn.configID, actionID: builtIn.actionID, icon: .symbol(builtIn.symbol))
        }
        if BuiltInButtonActions.unsupported.contains(identifier) {
            diagnostics.append(SettingsDiagnostic(kind: .unknownAction, path: path, message: "'\(identifier)' is not supported in cmux-next yet"))
            return nil
        }
        return TabBarButtonSpec(id: id ?? identifier, actionID: identifier)
    }
}
