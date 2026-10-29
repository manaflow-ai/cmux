public import CmuxNextDesign

/// Debug Settings of what a browser page shows before its document paints
/// (DEV and NIGHTLY; Release and RC never activate the store, so they keep the
/// defaults). Labels are English developer text, as for every Debug Settings
/// section (`TunableSection`).
public nonisolated struct BrowserPageTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "browserPage", title: "Browser Page Loading", symbol: "square.dashed", order: 49)

    /// On (the default): between a navigation committing and its document
    /// settling, the page area keeps the theme page background instead of the
    /// engine's white (`CEFTab+LoadingBackground`, `WebKitTab.pageDidFinish`).
    /// Off: the engine's white shows while the page loads, which flashes in a
    /// dark theme.
    public static let loadingBackground = Tunable<Bool>.toggle(
        "browserPage.loadingBackground", section, "Load pages on the theme color",
        help: "While a page loads, the page area keeps the pane's theme background instead of the engine's white, so a dark theme does not flash white before the page paints. A loaded page with no background of its own is still white.",
        default: true, code: "BrowserPageTunables.loadingBackground")

    /// The webview UI pointer picker (plans/cmux-next/ui-pointer.md). Off by
    /// default while the first webview slice is being dogfooded; when on,
    /// Toggle Browser Design Mode becomes the picker shortcut and toolbar action.
    public static let uiPointer = Tunable<Bool>.toggle(
        "browserPage.uiPointer", section, "UI pointer picker",
        help: "Enables the webview picker that highlights an element on hover and attaches its DOM, styles, component metadata and crop to the agent composer.",
        default: false, code: "BrowserPageTunables.uiPointer")

    public static var all: [TunableDescriptor] { [loadingBackground.descriptor, uiPointer.descriptor] }
}
