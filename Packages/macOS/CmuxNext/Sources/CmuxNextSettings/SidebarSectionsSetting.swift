public import CmuxNextDesign

/// Parses the sidebar section settings (`sidebar.*` in cmux.json). A
/// missing key is its default; a bad value is the default plus a diagnostic.
public nonisolated enum SidebarSectionsSetting {
    public static let lookPath = ["sidebar", "sectionLook"]
    public static let topSharePath = ["sidebar", "topBandMaxShare"]
    public static let bottomSharePath = ["sidebar", "bottomBandMaxShare"]
    public static let scrollPath = ["sidebar", "pinnedBandsScroll"]
    /// R87: the key nightly-next builds wrote before the rename, read for
    /// one release when `sidebar.pinnedBandsScroll` is absent. Remove after it.
    static let legacyScrollPath = ["sidebar", "stickyBandsScroll"]
    public static let showWorkspaceTabsPath = ["sidebar", "showWorkspaceTabs"]
    public static let minimalModePath = ["sidebar", "minimalMode"]
    public static let dockModePath = ["sidebar", "dockMode"]

    static func dockModeDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(dockModePath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.dockMode", "Sidebar Dock"),
                          help: SettingsText.keyed("settings.sidebar.dockMode.help", "Shows destinations, agent state and pinned workspaces at the bottom of the window."),
                          kind: .choice([
                              SettingChoice(SidebarDockMode.off.rawValue, SettingsText.keyed("settings.choice.off", "Off")),
                              SettingChoice(SidebarDockMode.reserved.rawValue, SettingsText.keyed("settings.choice.dockReserved", "Reserved Strip")),
                              SettingChoice(SidebarDockMode.overlay.rawValue, SettingsText.keyed("settings.choice.dockOverlay", "Hover Overlay")),
                          ]),
                          default: .string(SidebarDockMode.off.rawValue),
                          keywords: ["sidebar", "dock", "destinations", "agents", "workspaces", "bottom", "hover"])
    }

    static func minimalModeDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(minimalModePath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.minimalMode", "Minimal Mode"),
                          help: SettingsText.keyed("settings.sidebar.minimalMode.help",
                                                   "Hides the chosen sections until the pointer is over the sidebar."),
                          kind: .choice([
                              SettingChoice(SidebarMinimalMode.off.rawValue, SettingsText.keyed("settings.choice.off", "Off")),
                              SettingChoice(SidebarMinimalMode.bottom.rawValue,
                                            SettingsText.keyed("settings.choice.minimalBottom", "Settings and Account Row")),
                              SettingChoice(SidebarMinimalMode.top.rawValue, SettingsText.keyed("settings.choice.minimalTop", "Top Sections")),
                              SettingChoice(SidebarMinimalMode.both.rawValue, SettingsText.keyed("settings.choice.minimalBoth", "Top and Bottom")),
                          ]),
                          default: .string(SidebarSectionsPreferences.defaults.minimalMode.rawValue),
                          keywords: ["sidebar", "minimal", "hide", "hover", "settings", "account"])
    }

    static func showWorkspaceTabsDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(showWorkspaceTabsPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.showWorkspaceTabs", "Show Workspace Tabs"),
                          help: SettingsText.keyed("settings.sidebar.showWorkspaceTabs.help", "Lists tabs beneath each workspace in the sidebar."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showWorkspaceTabs),
                          keywords: ["sidebar", "workspace", "tabs"])
    }
    /// The looks the setting accepts (CmuxNextSidebar.SectionsLookVariant).
    public static let looks = ["quiet", "card", "tray", "lines", "linesIcons"]

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SidebarSectionsPreferences {
        var result = SidebarSectionsPreferences.defaults
        if let value = root.value(at: lookPath) {
            if let text = value.stringValue, looks.contains(text) {
                result.look = text
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.sectionLook",
                                                      message: "expected one of " + looks.map { "\"\($0)\"" }.joined(separator: ", ")))
            }
        }
        result.topBandMaxShare = share(root, topSharePath, "sidebar.topBandMaxShare", fallback: result.topBandMaxShare, &diagnostics)
        result.bottomBandMaxShare = share(root, bottomSharePath, "sidebar.bottomBandMaxShare", fallback: result.bottomBandMaxShare, &diagnostics)
        // Together the shares leave the list at least a fifth: past 0.8 both
        // shrink in proportion (each value alone stays valid, so setting one
        // never needs the other changed first).
        let sum = result.topBandMaxShare + result.bottomBandMaxShare
        if sum > SidebarSectionsPreferences.maxShareSum {
            let scale = SidebarSectionsPreferences.maxShareSum / sum
            result.topBandMaxShare *= scale
            result.bottomBandMaxShare *= scale
        }
        let scroll = ColumnLayoutSettings.path(root, scrollPath, legacy: legacyScrollPath)
        if let value = root.value(at: scroll) {
            if let flag = value.boolValue {
                result.pinnedBandsScroll = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: scroll.joined(separator: "."), message: "expected true or false"))
            }
        }
        if let value = root.value(at: minimalModePath) {
            if let text = value.stringValue, let mode = SidebarMinimalMode(rawValue: text) {
                result.minimalMode = mode
            } else {
                let choices = SidebarMinimalMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.minimalMode", message: "expected one of " + choices))
            }
        }
        if let value = root.value(at: showWorkspaceTabsPath) {
            if let flag = value.boolValue {
                result.showWorkspaceTabs = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.showWorkspaceTabs", message: "expected true or false"))
            }
        }
        if let value = root.value(at: dockModePath) {
            if let text = value.stringValue, let mode = SidebarDockMode(rawValue: text) {
                result.dockMode = mode
            } else {
                let choices = SidebarDockMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.dockMode", message: "expected one of " + choices))
            }
        }
        return result
    }

    private static func share(_ root: JSONValue, _ path: [String], _ name: String, fallback: Double,
                              _ diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: path) else { return fallback }
        guard let number = value.doubleValue, SidebarSectionsPreferences.shareRange.contains(number) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: name,
                                                  message: "expected a share of the sidebar height from 0.1 to 0.9, such as 0.33"))
            return fallback
        }
        return number
    }
}
