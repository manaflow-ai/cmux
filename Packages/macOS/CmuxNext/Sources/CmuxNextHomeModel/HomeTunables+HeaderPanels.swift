public import CmuxNextDesignTokens

extension HomeTunables {
    /// The Home transcript header's top-right Memory Inspector toggle (Leo 2026-10-20: "Use
    /// top-right toggle buttons (like Claude desktop) ... Nothing opens by default"; the right
    /// sidebar toggle went with the right sidebar, #41025). Off by default (Lawrence 2026-10-22:
    /// "fix it so it's simple, like tf are these buttons for"): Memory opens from the tab's
    /// right-click (Chief Actions), the palette and Show Memory in the Chief settings. On shows the toggle
    /// again.
    public static let headerPanelToggles = Tunable<Bool>.toggle(
        "home.headerPanelToggles", section, "Home header panel toggles",
        help: "A Chief conversation's Home header shows a toggle at its top right that opens and closes the Memory Inspector. Off (the default) hides it.",
        default: false, code: "HomeTunables.headerPanelToggles")

    /// The header panel tunables, registered beside ``all`` (DebugSettingsService).
    public static var headerPanels: [TunableDescriptor] { [headerPanelToggles.descriptor] }
}
