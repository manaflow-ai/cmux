public import CmuxNextDesign

extension HomeTunables {
    /// The Home transcript header's top-right panel toggles (Memory, Right Sidebar; Leo
    /// 2026-10-20: "Use top-right toggle buttons (like Claude desktop) ... Nothing opens by
    /// default"). On by default; off hides the cluster, and the panels open only from the
    /// palette, their shortcuts and Show Memory in the Chief settings.
    public static let headerPanelToggles = Tunable<Bool>.toggle(
        "home.headerPanelToggles", section, "Home header panel toggles",
        help: "The Home conversation header shows toggles at its top right that open and close the Memory Inspector and the right sidebar. Off hides them.",
        default: true, code: "HomeTunables.headerPanelToggles")

    /// The header panel tunables, registered beside ``all`` (DebugSettingsService).
    public static var headerPanels: [TunableDescriptor] { [headerPanelToggles.descriptor] }
}
