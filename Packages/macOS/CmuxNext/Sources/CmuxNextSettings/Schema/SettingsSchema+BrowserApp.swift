/// Keys only cmux-browser reads (the separate Chromium-based app that shares cmux.json). They are
/// in the export, validation and docs like every key, so cmux.json stays one documented file, but
/// `consumers` keeps them out of the cmux-next Settings page and palette, where they would be
/// controls that change nothing. Defaults are cmux-browser's (`cmux_layout_config.h`).
nonisolated enum BrowserAppSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let toolbar = SettingsText.keyed("settings.group.toolbar", "Toolbar")
        let addressBar = SettingsText.keyed("settings.group.addressBar", "Address Bar")
        let columns = SettingsText.keyed("settings.group.columns", "Columns")
        let window = SettingsText.keyed("settings.group.window", "Window")
        let sidebar = SettingsText.keyed("settings.group.sidebar", "Sidebar")
        let theme = SettingsText.keyed("settings.default.theme", "Theme")
        let rows: [SettingDescriptor] = [
            button("back", SettingsText.keyed("settings.browser.toolbar.back", "Back Button"), toolbar, default: true),
            button("forward", SettingsText.keyed("settings.browser.toolbar.forward", "Forward Button"), toolbar, default: true),
            button("reload", SettingsText.keyed("settings.browser.toolbar.reload", "Reload Button"), toolbar, default: true),
            button("home", SettingsText.keyed("settings.browser.toolbar.home", "Home Button"), toolbar, default: false),
            button("extensions", SettingsText.keyed("settings.browser.toolbar.extensions", "Extensions Button"), toolbar, default: true),
            button("downloads", SettingsText.keyed("settings.browser.toolbar.downloads", "Downloads Button"), toolbar, default: true),
            button("media", SettingsText.keyed("settings.browser.toolbar.media", "Media Controls Button"), toolbar, default: true),
            button("profile", SettingsText.keyed("settings.browser.toolbar.profile", "Profile Button"), toolbar, default: true),
            button("menu", SettingsText.keyed("settings.browser.toolbar.menu", "Menu Button"), toolbar, default: true),
            SettingDescriptor(
                ["browser", "omnibox", "color"], section: .browser, group: addressBar,
                title: SettingsText.keyed("settings.browser.omnibox.color", "Address Bar Color"),
                kind: .color, default: nil, defaultLabel: theme, keywords: ["omnibox", "address bar", "url bar", "color"]
            ),
            SettingDescriptor(
                ["browser", "omnibox", "popupColor"], section: .browser, group: addressBar,
                title: SettingsText.keyed("settings.browser.omnibox.popupColor", "Suggestions Color"),
                kind: .color, default: nil, defaultLabel: theme, keywords: ["omnibox", "suggestions", "popup", "color"]
            ),
            SettingDescriptor(
                ["browser", "omnibox", "popupHoverColor"], section: .browser, group: addressBar,
                title: SettingsText.keyed("settings.browser.omnibox.popupHoverColor", "Highlighted Suggestion Color"),
                kind: .color, default: nil, defaultLabel: theme, keywords: ["omnibox", "suggestions", "hover", "highlight", "color"]
            ),
            SettingDescriptor(
                ["layout", "stripMargin"], section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.stripMargin", "Strip Margin"),
                help: SettingsText.keyed("settings.layout.stripMargin.help", "Space between the window edge and the columns."),
                kind: .number(SettingNumber(0...40, step: 1, unit: .points)), default: .number(0),
                keywords: ["margin", "inset", "columns", "strip"]
            ),
            SettingDescriptor(
                ["layout", "columnWidthPresets"], section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.columnWidthPresets", "Column Width Presets"),
                help: SettingsText.keyed("settings.layout.columnWidthPresets.help",
                                        "Widths a column cycles through, as fractions of the visible strip width."),
                kind: .numberList(SettingNumber(0.1...2, step: 0.0001, unit: .fraction)),
                default: .array([.number(1), .number(0.6667), .number(0.5), .number(0.3333)]),
                keywords: ["column", "width", "presets", "cycle", "niri"]
            ),
            SettingDescriptor(
                ["window", "trafficLightClearance"], section: .appearance, group: window,
                title: SettingsText.keyed("settings.window.trafficLightClearance", "Traffic Light Clearance"),
                help: SettingsText.keyed("settings.window.trafficLightClearance.help",
                                        "Space kept free for the window's close, minimize and zoom buttons."),
                kind: .number(SettingNumber(0...160, step: 1, unit: .points)), default: .number(72),
                keywords: ["traffic lights", "window buttons", "rail", "clearance"]
            ),
            SettingDescriptor(
                ["sidebar", "workspaceIcons"], section: .general, group: sidebar,
                title: SettingsText.keyed("settings.sidebar.workspaceIcons", "Workspace Icons"),
                help: SettingsText.keyed("settings.sidebar.workspaceIcons.help",
                                        "An icon for each workspace title. \"*\" sets the icon of every other workspace; an empty icon hides it."),
                kind: .stringMap, default: .object([:]), keywords: ["workspace", "icon", "glyph", "emoji", "rail"]
            ),
        ]
        return rows.map { $0.consumed(by: [.cmuxBrowser]) }
    }

    /// `browser.toolbar.<button>`: whether cmux-browser's toolbar shows that button.
    private static func button(_ name: String, _ title: SettingText, _ group: SettingText, default value: Bool) -> SettingDescriptor {
        SettingDescriptor(
            ["browser", "toolbar", name], section: .browser, group: group, title: title,
            kind: .toggle, default: .bool(value), keywords: ["toolbar", "button", name]
        )
    }
}
