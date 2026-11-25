public import CmuxNextDesign

/// The sidebar prototypes Leo asked for as first-class toggles (2026-10-21: "not even, like,
/// plugins. They're just toggles in the app store area"): each is on when its cmux-next.json key
/// (an App Store card, Settings, the palette, `cmux settings`) or its Debug tunable is on. Every
/// reader goes through these, so the key works in Release, where tunables are inert.
@MainActor
extension SidebarTunables {
    /// `sidebar.workspacesAsTabs`: one line per workspace, and Cmd-Shift-[ / ] step workspaces.
    public static var workspacesAsTabsOn: Bool {
        DesignSettings.shared.sidebarSections.workspacesAsTabs || workspacesAsTabs.value
    }

    /// `sidebar.chromeGroups`: the connected group chip and capped rail.
    public static var groupChromeShapeOn: Bool {
        DesignSettings.shared.sidebarSections.chromeGroups || groupChromeShape.value
    }

    /// `sidebar.sideBySide`: navigate on release, drop a row on a pane edge to show it beside.
    public static var multiViewOn: Bool {
        DesignSettings.shared.sidebarSections.sideBySide || multiView.value
    }
}
