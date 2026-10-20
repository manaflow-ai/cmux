public import CmuxNextDesign

/// Debug Settings of a Chromium page while its window or pane resizes (DEV
/// and NIGHTLY; Release and RC never activate the store, so they keep the
/// defaults). Labels are English developer text, as for every Debug
/// Settings section (`TunableSection`).
public nonisolated struct BrowserResizeTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "browserResize", title: "Browser Resize", symbol: "arrow.up.left.and.arrow.down.right", order: 48)

    /// On (the default): the gap beside a Chromium page's last frame while it
    /// lays out at a new size shows the page's own background color
    /// (`CEFTab+ResizeBackdrop`). Off: the gap shows Chromium's white and the
    /// pane ground, or the window backdrop over Liquid Glass.
    public static let pageBackdrop = Tunable<Bool>.toggle(
        "browserResize.pageBackdrop", section, "Fill resize gaps with the page color",
        help: "While a Chromium page lays out at a new window or pane size, the gap beside its last frame shows the page's own background color. Off shows Chromium's white and the pane ground.",
        default: true, code: "BrowserResizeTunables.pageBackdrop")

    public static var all: [TunableDescriptor] { [pageBackdrop.descriptor] }
}
