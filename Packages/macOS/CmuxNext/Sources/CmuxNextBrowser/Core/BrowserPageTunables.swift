public import CmuxNextDesign

/// Debug Settings of what a browser page shows before its document paints
/// (DEV and NIGHTLY; Release and RC never activate the store, so they keep the
/// defaults). Labels are English developer text, as for every Debug Settings
/// section (`TunableSection`).
public nonisolated struct BrowserPageTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "browserPage", title: "Browser Page Loading", symbol: "square.dashed", order: 49)

    /// The webview UI pointer picker (plans/cmux-next/ui-pointer.md). Off by
    /// default while the first webview slice is being dogfooded; when on,
    /// Toggle Browser Design Mode becomes the picker shortcut and toolbar action.
    public static let uiPointer = Tunable<Bool>.toggle(
        "browserPage.uiPointer", section, "UI pointer picker",
        help: "Enables the webview picker that highlights an element on hover and attaches its DOM, styles, component metadata and crop to the agent composer.",
        default: false, code: "BrowserPageTunables.uiPointer")

    public static var all: [TunableDescriptor] { [uiPointer.descriptor, CEFSpareWindow.pageSetting.descriptor] }
}
