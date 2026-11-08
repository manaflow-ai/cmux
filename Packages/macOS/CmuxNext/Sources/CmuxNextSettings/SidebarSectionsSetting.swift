public import CmuxNextDesign

/// Parses the sidebar section settings (`sidebar.*` in cmux.json). A
/// missing key is its default; a bad value is the default plus a diagnostic.
public nonisolated enum SidebarSectionsSetting {
    // The paths, defaults, ranges and choices are generated from schemas/settings/source/sidebar.json
    // (SettingsSchema+Sidebar*.generated.swift).
    /// R87: the key nightly-next builds wrote before the rename, read for
    /// one release when `sidebar.pinnedBandsScroll` is absent. Remove after it.
    static let legacyScrollPath = ["sidebar", "stickyBandsScroll"]

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SidebarSectionsPreferences {
        var result = SidebarSectionsPreferences.defaults
        result.look = lookDefault
        if let value = root.value(at: lookPath) {
            if let text = value.stringValue, lookValues.contains(text) {
                result.look = text
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.sectionLook",
                                                      message: "expected one of " + lookValues.map { "\"\($0)\"" }.joined(separator: ", ")))
            }
        }
        result.topBandMaxShare = share(root, topSharePath, "sidebar.topBandMaxShare", fallback: topShareDefault, range: topShareRange, &diagnostics)
        result.bottomBandMaxShare = share(root, bottomSharePath, "sidebar.bottomBandMaxShare", fallback: bottomShareDefault, range: bottomShareRange,
                                          &diagnostics)
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
        result.pinnedBandsScroll = scrollDefault
        if let value = root.value(at: scroll) {
            if let flag = value.boolValue {
                result.pinnedBandsScroll = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: scroll.joined(separator: "."), message: "expected true or false"))
            }
        }
        result.minimalMode = ColumnLayoutSettings.choice(root, minimalModePath, fallback: minimalModeDefault, diagnostics: &diagnostics)
        result.sessionTree = flag(root, sessionTreePath, fallback: sessionTreeDefault, &diagnostics)
        result.showsTips = flag(root, tipsPath, fallback: tipsDefault, &diagnostics)
        SidebarNavigationSetting.parse(root, into: &result.navigation, diagnostics: &diagnostics)
        result.workspaceRow = WorkspaceRowSetting().parse(root, diagnostics: &diagnostics)
        result.showProjects = flag(root, showProjectsPath, fallback: showProjectsDefault, &diagnostics)
        result.showSpaces = flag(root, showSpacesPath, fallback: showSpacesDefault, &diagnostics)
        result.showProfileControl = flag(root, showProfileControlPath, fallback: showProfileControlDefault, &diagnostics)
        result.showSearchButton = flag(root, showSearchButtonPath, fallback: showSearchButtonDefault, &diagnostics)
        result.showNewWorkspaceChooser = flag(root, showNewWorkspaceChooserPath, fallback: showNewWorkspaceChooserDefault, &diagnostics)
        result.workspacesAsTabs = flag(root, workspacesAsTabsPath, fallback: workspacesAsTabsDefault, &diagnostics)
        result.chromeGroups = flag(root, chromeGroupsPath, fallback: chromeGroupsDefault, &diagnostics)
        result.sideBySide = flag(root, sideBySidePath, fallback: sideBySideDefault, &diagnostics)
        result.noFade = flag(root, noFadePath, fallback: noFadeDefault, &diagnostics)
        result.controlsOnHover = flag(root, controlsOnHoverPath, fallback: controlsOnHoverDefault, &diagnostics)
        result.minimal = flag(root, minimalPath, fallback: minimalDefault, &diagnostics)
        result.detailedStatusIcons = flag(root, detailedStatusIconsPath, fallback: detailedStatusIconsDefault, &diagnostics)
        result.showTimestamps = flag(root, showTimestampsPath, fallback: showTimestampsDefault, &diagnostics)
        result.showColors = flag(root, showColorsPath, fallback: showColorsDefault, &diagnostics)
        result.workspaceColorIndicator = WorkspaceColorsSetting.parseIndicatorStyle(root, fallback: WorkspaceColorsSetting.indicatorStyleDefault, &diagnostics)
        result.showLocalMachine = flag(root, showLocalMachinePath, fallback: showLocalMachineDefault, &diagnostics)
        result.groupHeaderMemberCount = flag(root, groupHeaderMemberCountPath, fallback: groupHeaderMemberCountDefault, &diagnostics)
        result.groupHeaderUnreadCount = flag(root, groupHeaderUnreadCountPath, fallback: groupHeaderUnreadCountDefault, &diagnostics)
        result.groupHeaderBackground = ColumnLayoutSettings.choice(root, groupHeaderBackgroundPath, fallback: groupHeaderBackgroundDefault,
                                                                   diagnostics: &diagnostics)
        result.groupPalette = ColumnLayoutSettings.choice(root, groupPalettePath, fallback: groupPaletteDefault, diagnostics: &diagnostics)
        result.groupGradient = ColumnLayoutSettings.choice(root, groupGradientPath, fallback: groupGradientDefault, diagnostics: &diagnostics)
        let priority = SidebarPriorityViewSetting.self
        result.priorityViewEnabled = flag(root, priority.enabledPath, fallback: priority.enabledDefault, &diagnostics)
        result.priorityViewShown = flag(root, priority.shownPath, fallback: priority.shownDefault, &diagnostics)
        result.groupBy = ColumnLayoutSettings.choice(root, groupByPath, fallback: groupByDefault, diagnostics: &diagnostics)
        result.density = ColumnLayoutSettings.choice(root, densityPath, fallback: densityDefault, diagnostics: &diagnostics)
        result.textSize = ColumnLayoutSettings.choice(root, textSizePath, fallback: textSizeDefault, diagnostics: &diagnostics)
        result.style = ColumnLayoutSettings.choice(root, stylePath, fallback: styleDefault, diagnostics: &diagnostics)
        result.showChats = flag(root, showChatsPath, fallback: showChatsDefault, &diagnostics)
        return result
    }

    private static func flag(_ root: JSONValue, _ path: [String], fallback: Bool, _ diagnostics: inout [SettingsDiagnostic]) -> Bool {
        guard let value = root.value(at: path) else { return fallback }
        guard let flag = value.boolValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
            return fallback
        }
        return flag
    }

    private static func share(_ root: JSONValue, _ path: [String], _ name: String, fallback: Double, range: ClosedRange<Double>,
                              _ diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: path) else { return fallback }
        guard let number = value.doubleValue, range.contains(number) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: name,
                                                  message: "expected a share of the sidebar height from 0.1 to 0.9, such as 0.33"))
            return fallback
        }
        return number
    }
}
