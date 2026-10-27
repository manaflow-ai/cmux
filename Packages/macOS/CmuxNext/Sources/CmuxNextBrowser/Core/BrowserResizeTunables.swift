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
    /// An upper bound: the wait never passes half the shortest frame of all
    /// displays (`CEFResizeSyncDeadline`: 8 ms at 60 Hz, 4 ms once a display
    /// runs at 120 Hz). A change applies at the page's next show or display change.
    /// 0: never wait (the page shows its last frame until the new one comes).
    public static let syncDeadline = Tunable<Double>.number(
        "browserResize.syncDeadline", section, "Hosted page resize wait",
        help: "How long a pane resize waits for a layer-hosted Chromium page to draw at the new size, so the page and the pane change in the same frame. Never more than half the shortest display frame (4 ms with a 120 Hz display). Applies at the page's next show. 0 never waits.",
        default: 0.008, range: 0...0.1, step: 0.001, unit: .seconds, code: "BrowserResizeTunables.syncDeadline")

    /// During the window's live resize, how long each Chromium page (hosted or
    /// not) may hold the window's frame for its frame at the new size (fork
    /// API 27; Chromium itself waited up to 500 ms), under the same cap as
    /// `syncDeadline` (half the shortest display frame). 0 never waits.
    public static let liveResizeDeadline = Tunable<Double>.number(
        "browserResize.liveResizeDeadline", section, "Page wait during window resize",
        help: "While the window is resized, how long each Chromium page may hold a frame to draw at the new size, so it resizes with the window. Never more than half the shortest display frame. 0 never waits; the page then shows its last frame until it draws.",
        default: 0.016, range: 0...0.1, step: 0.001, unit: .seconds, code: "BrowserResizeTunables.liveResizeDeadline")

    /// On (the default): while a person drags a divider or a column or row edge, a Chromium page keeps
    /// the size it had when the drag began, anchored at its top-left corner and clipped to its pane
    /// (any gap in the page's own color), and lays out once when the pane's frame is final
    /// (`CEFTabContentView.paneResizeGestureDidChange`). Off: the page lays out at every frame's
    /// size, some frames behind the pane (Chromium draws in another process).
    public static let holdDuringDrag = Tunable<Bool>.toggle(
        "browserResize.holdDuringDrag", section, "Keep the page's size while a divider is dragged",
        help: "While a pane divider or edge is dragged, a Chromium page keeps its size and moves with the pane, and lays out once when the drag lands. Off lays the page out at every size, some frames behind the divider.",
        default: true, code: "BrowserResizeTunables.holdDuringDrag")

    public static var all: [TunableDescriptor] {
        [pageBackdrop.descriptor, layerHosting.descriptor, syncDeadline.descriptor, liveResizeDeadline.descriptor, holdDuringDrag.descriptor]
    }
}
