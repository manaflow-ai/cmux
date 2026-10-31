public import CmuxNextDesign

/// Where the window chrome sits (R109): `sidebar.side` and
/// `sidebar.spacesPosition` (and `sidebar.spacesVisibility`, cx-5k3r), the
/// tab bar's `tabs.barPosition` and `tabs.barOrder`, and the browser
/// toolbar's `browser.toolbarPosition` in cmux-next.json. A missing key is the
/// default; a bad value is the default plus a diagnostic.
public nonisolated struct ChromePlacementSetting {
    public nonisolated init() {}
    public static let sidebarSidePath = ["sidebar", "side"]
    public static let spacesPositionPath = ["sidebar", "spacesPosition"]
    public static let spacesVisibilityPath = ["sidebar", "spacesVisibility"]
    public static let tabBarPositionPath = ["tabs", "barPosition"]
    public static let tabBarOrderPath = ["tabs", "barOrder"]
    public static let browserToolbarPositionPath = ["browser", "toolbarPosition"]

    /// The title bar the window uses: `window.titlebar`, also while tab bars
    /// sit at the bottom (user 2026-10-28: no title strip there, to save
    /// space). The traffic lights then sit on the sidebar's header, or the
    /// main pane starts below their row (`WindowTitlebar.cardTopInset`).
    public static func effectiveTitlebar(_ snapshot: CmuxConfigSnapshot) -> TitlebarStyle {
        snapshot.titlebar
    }

    static func parse(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        snapshot.sidebarSide = choice(root, sidebarSidePath, fallback: .left, &snapshot.diagnostics)
        snapshot.spacesPosition = choice(root, spacesPositionPath, fallback: .bottom, &snapshot.diagnostics)
        snapshot.spacesVisibility = choice(root, spacesVisibilityPath, fallback: .hover, &snapshot.diagnostics)
        snapshot.tabBarPosition = choice(root, tabBarPositionPath, fallback: .top, &snapshot.diagnostics)
        snapshot.tabBarOrder = choice(root, tabBarOrderPath, fallback: .aboveToolbar, &snapshot.diagnostics)
        snapshot.browserToolbarPosition = choice(root, browserToolbarPositionPath, fallback: .top, &snapshot.diagnostics)
        _ = PaneToolbarButtonsSetting.parse(root, diagnostics: &snapshot.diagnostics) // the app reads the root (`current`)
        _ = SidebarSurfaceSetting.parse(root, diagnostics: &snapshot.diagnostics) // applied from the root (`applySidebarSurface`)
    }

    private static func choice<Value: RawRepresentable & CaseIterable>(
        _ root: JSONValue, _ path: [String], fallback: Value, _ diagnostics: inout [SettingsDiagnostic]
    ) -> Value where Value.RawValue == String {
        guard let value = root.value(at: path) else { return fallback }
        guard let text = value.stringValue, let parsed = Value(rawValue: text) else {
            let choices = Value.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected one of \(choices)"))
            return fallback
        }
        return parsed
    }

    static func sidebarSideDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(sidebarSidePath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.side", "Sidebar Side"),
                          help: SettingsText.keyed("settings.sidebar.side.help",
                                                   "The window edge the sidebar sits on. On the right, the window buttons sit over the tab bar."),
                          kind: .choice([
                              SettingChoice(SidebarSide.left.rawValue, SettingsText.keyed("settings.choice.left", "Left")),
                              SettingChoice(SidebarSide.right.rawValue, SettingsText.keyed("settings.choice.right", "Right")),
                          ]),
                          default: .string(SidebarSide.left.rawValue),
                          keywords: ["sidebar", "side", "left", "right", "position", "edge", "layout"])
    }

    static func tabBarPositionDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(tabBarPositionPath, section: .general, group: group,
                          title: SettingsText.keyed("settings.tabs.barPosition", "Tab Bar Position"),
                          help: SettingsText.keyed("settings.tabs.barPosition.help",
                                                   "Where each pane's tab bar sits. At the bottom, the panes reach the top of the window; the window buttons never cover a pane."),
                          kind: .choice([
                              SettingChoice(TabBarPosition.top.rawValue, SettingsText.keyed("settings.choice.top", "Top")),
                              SettingChoice(TabBarPosition.bottom.rawValue, SettingsText.keyed("settings.choice.bottom", "Bottom")),
                          ]),
                          default: .string(TabBarPosition.top.rawValue),
                          keywords: ["tab bar", "tabs", "strip", "top", "bottom", "position", "layout", "pane"])
    }

    static func browserToolbarPositionDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(browserToolbarPositionPath, section: .general, group: group,
                          title: SettingsText.keyed("settings.browser.toolbarPosition", "Browser Toolbar Position"),
                          help: SettingsText.keyed("settings.browser.toolbarPosition.help",
                                                   "Where the address bar row of browser and Markdown panes sits. At the bottom, its suggestions and menus open upward."),
                          kind: .choice([
                              SettingChoice(ToolbarPosition.top.rawValue, SettingsText.keyed("settings.choice.top", "Top")),
                              SettingChoice(ToolbarPosition.bottom.rawValue, SettingsText.keyed("settings.choice.bottom", "Bottom")),
                          ]),
                          default: .string(ToolbarPosition.top.rawValue),
                          keywords: ["omnibar", "address bar", "toolbar", "url bar", "browser", "markdown", "top", "bottom", "position", "layout"])
    }

    static func tabBarOrderDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(tabBarOrderPath, section: .general, group: group,
                          title: SettingsText.keyed("settings.tabs.barOrder", "Tab Bar and Browser Toolbar"),
                          help: SettingsText.keyed("settings.tabs.barOrder.help",
                                                   "In a browser pane with the tab bar and the address bar on the same edge: the tab bar above the address bar, or below it."),
                          summary: SettingsText.keyed("settings.tabs.barOrder.summary", "Which sits on top in a browser pane"),
                          kind: .choice([
                              SettingChoice(TabBarOrder.aboveToolbar.rawValue,
                                            SettingsText.keyed("settings.choice.tabsAboveToolbar", "Tab Bar Above")),
                              SettingChoice(TabBarOrder.belowToolbar.rawValue,
                                            SettingsText.keyed("settings.choice.tabsBelowToolbar", "Tab Bar Below")),
                          ]),
                          default: .string(TabBarOrder.aboveToolbar.rawValue),
                          keywords: ["tab bar", "tabs", "toolbar", "omnibar", "address bar", "order", "browser", "layout"])
    }

    static func spacesPositionDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(spacesPositionPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.spacesPosition", "Spaces Position"),
                          help: SettingsText.keyed("settings.sidebar.spacesPosition.help",
                                                   "Where the spaces dots sit in the sidebar: under the window buttons or above the Settings row."),
                          kind: .choice([
                              SettingChoice(SpacesPosition.top.rawValue, SettingsText.keyed("settings.choice.top", "Top")),
                              SettingChoice(SpacesPosition.bottom.rawValue, SettingsText.keyed("settings.choice.bottom", "Bottom")),
                          ]),
                          default: .string(SpacesPosition.bottom.rawValue),
                          keywords: ["sidebar", "spaces", "rooms", "profiles", "dots", "top", "bottom", "position", "layout"])
    }

    static func spacesVisibilityDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(spacesVisibilityPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.spacesVisibility", "Show Spaces"),
                          help: SettingsText.keyed("settings.sidebar.spacesVisibility.help",
                                                   "Always keeps the spaces shown, also when the sidebar's controls show only on hover. On Hover lets them hide with the other controls then."),
                          kind: .choice([
                              SettingChoice(SpacesVisibilityMode.hover.rawValue, SettingsText.keyed("settings.choice.onHover", "On Hover")),
                              SettingChoice(SpacesVisibilityMode.always.rawValue, SettingsText.keyed("settings.choice.always", "Always")),
                          ]),
                          default: .string(SpacesVisibilityMode.hover.rawValue),
                          keywords: ["sidebar", "spaces", "rooms", "profiles", "dots", "hover", "hide", "show", "always", "visibility"])
    }
}

extension SettingsApplier {
    /// Copies the chrome placement keys into `design`, writing only changes.
    public static func applyPlacement(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        if design.sidebarSide != snapshot.sidebarSide { design.sidebarSide = snapshot.sidebarSide }
        if design.spacesPosition != snapshot.spacesPosition { design.spacesPosition = snapshot.spacesPosition }
        if design.spacesVisibility != snapshot.spacesVisibility { design.spacesVisibility = snapshot.spacesVisibility }
        if design.tabBarPosition != snapshot.tabBarPosition { design.tabBarPosition = snapshot.tabBarPosition }
        if design.tabBarOrder != snapshot.tabBarOrder { design.tabBarOrder = snapshot.tabBarOrder }
        if design.browserToolbarPosition != snapshot.browserToolbarPosition { design.browserToolbarPosition = snapshot.browserToolbarPosition }
        if design.paneBackgrounds != snapshot.paneBackgrounds { design.paneBackgrounds = snapshot.paneBackgrounds }
        applyChromeStyle(snapshot, to: design)
        applySidebarSurface(snapshot, to: design)
    }
}
