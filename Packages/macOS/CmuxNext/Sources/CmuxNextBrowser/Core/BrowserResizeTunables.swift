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

    /// While a page is layer hosted (`layerHosting`), how long a resize of
    /// its pane may hold the window's frame for Chromium's frame at the new
    /// size (fork API 27), so the page resizes in the same frame as the pane.
    /// An upper bound: the wait never passes half a frame of the window's
    /// display (`CEFResizeSyncDeadline`: 8 ms at 60 Hz, 4 ms at 120 Hz). A
    /// change applies at the page's next show or screen change.
    /// 0: never wait (the page shows its last frame until the new one comes).
    public static let syncDeadline = Tunable<Double>.number(
        "browserResize.syncDeadline", section, "Hosted page resize wait",
        help: "How long a pane resize waits for a layer-hosted Chromium page to draw at the new size, so the page and the pane change in the same frame. Never more than half a display frame (4 ms at 120 Hz). Applies at the page's next show. 0 never waits.",
        default: 0.008, range: 0...0.1, step: 0.001, unit: .seconds, code: "BrowserResizeTunables.syncDeadline")

    /// During the window's live resize, how long each Chromium page (hosted or
    /// not) may hold the window's frame for its frame at the new size (fork
    /// API 27; Chromium itself waited up to 500 ms). 0 never waits.
    public static let liveResizeDeadline = Tunable<Double>.number(
        "browserResize.liveResizeDeadline", section, "Page wait during window resize",
        help: "While the window is resized, how long each Chromium page may hold a frame to draw at the new size, so it resizes with the window. 0 never waits; the page then shows its last frame until it draws.",
        default: 0.016, range: 0...0.1, step: 0.001, unit: .seconds, code: "BrowserResizeTunables.liveResizeDeadline")

    public static var all: [TunableDescriptor] { [pageBackdrop.descriptor, layerHosting.descriptor, syncDeadline.descriptor, liveResizeDeadline.descriptor] }
}
