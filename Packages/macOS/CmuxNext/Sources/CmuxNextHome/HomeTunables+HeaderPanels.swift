public import CmuxNextDesign

extension HomeTunables {
    /// The Home transcript header's top-right panel toggles (Memory, Right Sidebar; Leo
    /// 2026-10-20: "Use top-right toggle buttons (like Claude desktop) ... Nothing opens by
    /// default"). Off by default (Lawrence 2026-10-22: "fix it so it's simple, like tf are these
    /// buttons for"): the header keeps no second row of buttons; Memory opens from the pane's ⋮
    /// (Chief Actions), the palette and Show Memory in the Chief settings, and the right sidebar from
    /// View > Toggle Right Sidebar (Option-Command-B). On shows the cluster again.
    public static let headerPanelToggles = Tunable<Bool>.toggle(
        "home.headerPanelToggles", section, "Home header panel toggles",
        help: "The Home conversation header shows toggles at its top right that open and close the Memory Inspector and the right sidebar. Off (the default) hides them.",
        default: false, code: "HomeTunables.headerPanelToggles")

    /// The header panel tunables, registered beside ``all`` (DebugSettingsService).
    public static var headerPanels: [TunableDescriptor] { [headerPanelToggles.descriptor] }
}
