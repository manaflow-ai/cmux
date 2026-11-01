public import CmuxNextDesign

/// `workspaceColors.indicatorStyle` (#25653): the key classic reads for the same choice, so one
/// cmux.json colors rows the same way in both apps (classic's `solidFill` reads as `fill`).
public nonisolated struct WorkspaceColorsSetting {
    public nonisolated init() {}
    public static let indicatorStylePath = ["workspaceColors", "indicatorStyle"]

    static func indicatorStyleDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(indicatorStylePath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.workspaceColors.indicatorStyle", "Workspace Color Style"),
                          help: SettingsText.keyed("settings.workspaceColors.indicatorStyle.help",
                                                   "How a workspace's color shows in the sidebar: a dot before its name, a bar down the row's edge, or the whole row filled with the color."),
                          kind: .choice(WorkspaceColorIndicatorStyle.allCases.map { style in
                              switch style {
                              case .dot: SettingChoice(style.rawValue, SettingsText.keyed("settings.choice.workspaceColorDot", "Dot"))
                              case .leftRail: SettingChoice(style.rawValue, SettingsText.keyed("settings.choice.workspaceColorLeftRail", "Left Rail"))
                              case .fill: SettingChoice(style.rawValue, SettingsText.keyed("settings.choice.workspaceColorFill", "Fill Row"))
                              }
                          }),
                          default: .string(SidebarSectionsPreferences.defaults.workspaceColorIndicator.rawValue),
                          keywords: ["sidebar", "workspace", "color", "colour", "tint", "fill", "row", "background",
                                     "rail", "bar", "dot", "highlight", "indicator", "review", "ready"])
    }

    static func parseIndicatorStyle(_ root: JSONValue, fallback: WorkspaceColorIndicatorStyle,
                                    _ diagnostics: inout [SettingsDiagnostic]) -> WorkspaceColorIndicatorStyle {
        guard let value = root.value(at: indicatorStylePath) else { return fallback }
        guard let text = value.stringValue, let style = WorkspaceColorIndicatorStyle(setting: text) else {
            let choices = WorkspaceColorIndicatorStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: indicatorStylePath.joined(separator: "."),
                                                  message: "expected one of " + choices))
            return fallback
        }
        return style
    }
}
