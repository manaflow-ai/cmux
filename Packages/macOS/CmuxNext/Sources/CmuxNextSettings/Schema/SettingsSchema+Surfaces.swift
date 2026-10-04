public import CmuxNextDesign

/// Appearance > Surfaces (Lawrence R55, plans/cmux-next/surface-backgrounds.md):
/// a color and an opacity for each `SurfaceKind`. Both default to the
/// window's (no value: the surface shows the window's one backdrop), so the
/// rows are optional overrides; the CLI, MCP and the palette reach them
/// through the normal settings path.
nonisolated enum SurfaceSettingsSchema {
    /// One surface's two row titles. Keys are literals, so the string
    /// catalog check sees each one.
    struct Titles {
        let kind: SurfaceKind
        let color: SettingText
        let opacity: SettingText
    }

    static var titles: [Titles] {
        [
            Titles(kind: .sidebar,
                   color: SettingsText.keyed("settings.appearance.surfaces.sidebar.color", "Sidebar Color"),
                   opacity: SettingsText.keyed("settings.appearance.surfaces.sidebar.opacity", "Sidebar Opacity")),
            Titles(kind: .tabBar,
                   color: SettingsText.keyed("settings.appearance.surfaces.tabBar.color", "Tab Bar Color"),
                   opacity: SettingsText.keyed("settings.appearance.surfaces.tabBar.opacity", "Tab Bar Opacity")),
            Titles(kind: .terminal,
                   color: SettingsText.keyed("settings.appearance.surfaces.terminal.color", "Terminal Color"),
                   opacity: SettingsText.keyed("settings.appearance.surfaces.terminal.opacity", "Terminal Opacity")),
            Titles(kind: .agentPane,
                   color: SettingsText.keyed("settings.appearance.surfaces.agentPane.color", "Agent Chat Color"),
                   opacity: SettingsText.keyed("settings.appearance.surfaces.agentPane.opacity", "Agent Chat Opacity")),
            Titles(kind: .settings,
                   color: SettingsText.keyed("settings.appearance.surfaces.settings.color", "Settings Color"),
                   opacity: SettingsText.keyed("settings.appearance.surfaces.settings.opacity", "Settings Opacity")),
            Titles(kind: .newTabPage,
                   color: SettingsText.keyed("settings.appearance.surfaces.newTabPage.color", "New Tab Page Color"),
                   opacity: SettingsText.keyed("settings.appearance.surfaces.newTabPage.opacity", "New Tab Page Opacity")),
            Titles(kind: .home,
                   color: SettingsText.keyed("settings.appearance.surfaces.home.color", "Home Color"),
                   opacity: SettingsText.keyed("settings.appearance.surfaces.home.opacity", "Home Opacity")),
            Titles(kind: .browserChrome,
                   color: SettingsText.keyed("settings.appearance.surfaces.browserChrome.color", "Browser Toolbar Color"),
                   opacity: SettingsText.keyed("settings.appearance.surfaces.browserChrome.opacity", "Browser Toolbar Opacity")),
            Titles(kind: .docks,
                   color: SettingsText.keyed("settings.appearance.surfaces.docks.color", "Docked Columns Color"),
                   opacity: SettingsText.keyed("settings.appearance.surfaces.docks.opacity", "Docked Columns Opacity")),
        ]
    }

    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.surfaces", "Surfaces")
        let sameAsWindow = SettingsText.keyed("settings.default.sameAsWindow", "Same as window")
        let windowOpacity = SettingsText.keyed("settings.default.windowOpacity", "Window opacity")
        let opacity = SettingNumber(SurfaceBackgroundSetting.opacityRange, step: 0.05, unit: .fraction)
        return titles.flatMap { row in
            let keywords = ["background", "surface", "color", "transparency", "opacity", row.kind.rawValue]
            return [
                SettingDescriptor(SurfaceBackgroundSetting.colorPath(row.kind), section: .appearance, group: group,
                                  title: row.color, kind: .color, default: nil, defaultLabel: sameAsWindow, keywords: keywords),
                SettingDescriptor(SurfaceBackgroundSetting.opacityPath(row.kind), section: .appearance, group: group,
                                  title: row.opacity, kind: .number(opacity), default: nil, defaultLabel: windowOpacity,
                                  keywords: keywords),
            ]
        }
    }
}
