import CmuxNextDesign

/// `sidebar.topLeftCluster` (``SidebarTopLeftCluster``): the sidebar's top-left corner group. Its own file so the
/// sidebar corner variants (2026-11-05 thunderdome) each keep a key of their own.
nonisolated enum SidebarTopLeftClusterSetting {
    static let path = ["sidebar", "topLeftCluster"]

    static func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(path, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.topLeftCluster", "Top Corner Layout"),
                          help: SettingsText.keyed("settings.sidebar.topLeftCluster.help",
                                                   "How the New Workspace button and the top of the sidebar meet the tabs. Every layout but Standard lines the + up with Search. Compact density keeps Standard."),
                          kind: .choice(SidebarTopLeftCluster.allCases.map { look in
                              switch look {
                              case .standard: SettingChoice(look.rawValue, SettingsText.keyed("settings.choice.sidebarStandard", "Standard"))
                              case .aligned: SettingChoice(look.rawValue, SettingsText.keyed("settings.choice.topLeftAligned", "Aligned with Search"))
                              case .headerRow: SettingChoice(look.rawValue, SettingsText.keyed("settings.choice.topLeftHeaderRow", "Header Row with Search"))
                              case .listRow: SettingChoice(look.rawValue, SettingsText.keyed("settings.choice.topLeftListRow", "New Workspace Row"))
                              case .tabLead: SettingChoice(look.rawValue, SettingsText.keyed("settings.choice.topLeftTabLead", "+ Before the Tabs"))
                              }
                          }),
                          default: .string(SidebarSectionsPreferences.defaults.topLeftCluster.rawValue),
                          keywords: ["sidebar", "corner", "new workspace", "plus", "search", "align", "header", "titlebar", "tabs", "layout"])
    }

    static func parse(_ root: JSONValue, fallback: SidebarTopLeftCluster, _ diagnostics: inout [SettingsDiagnostic]) -> SidebarTopLeftCluster {
        guard let value = root.value(at: path) else { return fallback }
        guard let text = value.stringValue, let look = SidebarTopLeftCluster(rawValue: text) else {
            let choices = SidebarTopLeftCluster.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected one of " + choices))
            return fallback
        }
        return look
    }
}
