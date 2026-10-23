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

    /// Off (the default): a Chromium page draws in its own child window over
    /// the pane. On: the page's pixels live in the cmux window's layer tree
    /// (fork API 26, `CEFHostedPageView`); the page window stays as a
    /// transparent input target. Applies to pages shown after the change.
    public static let layerHosting = Tunable<Bool>.toggle(
        "browserResize.layerHosting", section, "Host Chromium pages in the window's layers",
        help: "A Chromium page draws inside the cmux window's own layer tree, so it moves, clips and shows with the panes in one frame. Its page window stays on top only to take input. Needs Chromium fork API 26; applies when a page is shown next.",
        default: false, code: "BrowserResizeTunables.layerHosting")

    public static var all: [TunableDescriptor] { [pageBackdrop.descriptor, layerHosting.descriptor] }
}
