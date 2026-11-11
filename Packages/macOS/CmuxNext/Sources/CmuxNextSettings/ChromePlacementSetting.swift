public import CmuxNextDesign

/// Where the window chrome sits (R109): `sidebar.side` and
/// `sidebar.spacesPosition` (and `sidebar.spacesVisibility`, cx-5k3r), the
/// tab bar's `tabs.barPosition` and `tabs.barOrder`, and the browser
/// toolbar's `browser.toolbarPosition` in cmux-next.json. A missing key is the
/// default; a bad value is the default plus a diagnostic.
public nonisolated struct ChromePlacementSetting {
    public nonisolated init() {}

    /// The title bar the window uses: `window.titlebar`, also while tab bars
    /// sit at the bottom (user 2026-10-28: no title strip there, to save
    /// space). The traffic lights then sit on the sidebar's header, or the
    /// main pane starts below their row (`WindowTitlebar.cardTopInset`).
    public static func effectiveTitlebar(_ snapshot: CmuxConfigSnapshot) -> TitlebarStyle {
        snapshot.titlebar
    }

    static func parse(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        snapshot.sidebarSide = choice(root, sidebarSidePath, fallback: sidebarSideDefault, &snapshot.diagnostics)
        snapshot.spacesPosition = choice(root, spacesPositionPath, fallback: spacesPositionDefault, &snapshot.diagnostics)
        snapshot.spacesVisibility = choice(root, spacesVisibilityPath, fallback: spacesVisibilityDefault, &snapshot.diagnostics)
        snapshot.tabBarPosition = choice(root, tabBarPositionPath, fallback: tabBarPositionDefault, &snapshot.diagnostics)
        snapshot.tabBarOrder = choice(root, tabBarOrderPath, fallback: tabBarOrderDefault, &snapshot.diagnostics)
        snapshot.browserToolbarPosition = choice(root, browserToolbarPositionPath, fallback: browserToolbarPositionDefault, &snapshot.diagnostics)
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
        if design.browserShowsLoadingBar != snapshot.browserShowLoadingBar { design.browserShowsLoadingBar = snapshot.browserShowLoadingBar }
        if design.paneBackgrounds != snapshot.paneBackgrounds { design.paneBackgrounds = snapshot.paneBackgrounds }
        applyChromeStyle(snapshot, to: design)
        applySidebarSurface(snapshot, to: design)
    }
}
