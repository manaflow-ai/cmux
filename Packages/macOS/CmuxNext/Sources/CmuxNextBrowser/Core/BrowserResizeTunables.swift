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

    /// With `dragResize` at `resizeSync`, how long each Chromium page over a dragged pane (hosted or not) may hold the
    /// window's frame for its frame at the new size, from the drag's first move until its release landed (fork API 27),
    /// under the same cap as `syncDeadline`: half the shortest display frame, so no app frame waits past its display
    /// link's target time. 0 never waits.
    public static let dragResizeDeadline = Tunable<Double>.number(
        "browserResize.dragResizeDeadline", section, "Page wait during a divider drag",
        help: "With the Resize sync drag mode, how long each Chromium page beside a dragged divider may hold a frame to draw at the pane's new size, so the page and its pane change in the same frame. Never more than half the shortest display frame. Needs Chromium fork API 27. 0 never waits.",
        default: 0.016, range: 0...0.1, step: 0.001, unit: .seconds, code: "BrowserResizeTunables.dragResizeDeadline")

    /// How a Chromium page follows a pane divider or a column or row edge a person drags
    /// (Leo, 2026-10-26: "resizing the panes it propagates so fucking slowly to the right side browser tab
    /// thing"). Chromium draws in another process, so a page laid out at every frame's size shows each size
    /// some frames after its pane. `BrowserDragResize` names the three ways; the default is the one the
    /// split_resize harness measured to follow the drag best (`BrowserDragResize.default`).
    public static let dragResize = Tunable<BrowserDragResize>.choice(
        "browserResize.dragResize", section, "Page while a divider is dragged",
        help: "Live: the page lays out at every size, a few frames behind the divider. Hold: the page keeps its size and moves with the pane, clipped, and lays out once when the drag lands. Synced live: Chromium holds each app frame until the page has drawn at the new size (up to 500 ms); applies the next time Chromium starts. Resize sync: the page lays out at every size and each app frame waits for it up to the divider drag wait, at most half a display frame (Chromium fork API 27; Live below it).",
        default: BrowserDragResize.default, code: "BrowserResizeTunables.dragResize")

    /// On (the default; cmux-ad m6 1b, the interim browser contract until FRAME OWNER S5): through a keyboard resize a
    /// Chromium page keeps its size with its top-left corner on its pane's page area, so it moves with the pane's leading
    /// and top edges as the tab strip does; the pane clips it and the page's backdrop fills the rest. Off: S3's hold, the
    /// page fixed at the pane edges that do not move. Read when each key resize's hold begins. A kill switch only: it goes
    /// once the refactor owner's off/on film passes.
    public static let keyResizeTopLeft = Tunable<Bool>.toggle(
        "browserResize.keyResizeTopLeft", section, "Page moves with its pane in a keyboard resize",
        help: "On: through a keyboard resize a Chromium page keeps its size with its top-left corner on its pane, so it moves with the pane's left and top edges; the pane clips it. Off: the page stays at the pane edges that do not move.",
        default: true, code: "BrowserResizeTunables.keyResizeTopLeft")

    /// Off (the default): FRAME OWNER S5 is off; the rows above decide. On (cmux-ad m14, Lawrence 2026-11-05: "in every
    /// frame every browser shows live pixels rendered at that frame's pane size"): every Chromium page is hosted in the
    /// window's own layer tree (fork API 26, as `layerHosting` on), and in a key resize and a divider drag it never keeps an
    /// old size: it lays out at its pane's size in every frame and each page window holds that frame's commit for its frame
    /// at that size, up to `dragResizeDeadline` capped at half the shortest display frame (fork API 27). It overrides
    /// `dragResize` and `keyResizeTopLeft`. Read when each resize begins and when a page is shown, so one build films OFF
    /// and ON. Deleted after the ON films pass (S5 ON, then the switch-deletion PR).
    public static let framesOwnedByCommit = Tunable<Bool>.toggle(
        "motion.frameOwner.pages", section, "Page frame and size in one commit",
        help: "A Chromium page draws in the window's own layers and, in a keyboard resize or a divider drag, lays out at its pane's size in every frame; each frame waits for the page's frame at that size up to the divider drag wait, at most half a display frame. Needs Chromium fork API 27. Off: the rows above decide. Applies from the next resize; hosting applies when a page is shown next.",
        default: false, code: "BrowserResizeTunables.framesOwnedByCommit")

    /// `dragResize` as the override file holds it when Chromium starts, even when a restored tab starts
    /// Chromium before the store's own read of the file landed (`TunableStore.settledOverride`).
    static var dragResizeAtLaunch: BrowserDragResize {
        TunableStore.shared.settledOverride(dragResize.key).flatMap(BrowserDragResize.init(tunableValue:)) ?? dragResize.defaultValue
    }

    /// `dragResize` was the toggle `browserResize.holdDuringDrag` (cmux#25842): off is `live`, on `hold`.
    public static func registerRenames(_ store: TunableStore) {
        store.registerRename(from: "browserResize.holdDuringDrag", to: dragResize.key) { old in
            (old as? Bool).map { $0 ? BrowserDragResize.hold.rawValue : BrowserDragResize.live.rawValue }
        }
    }

    public static var all: [TunableDescriptor] {
        [pageBackdrop.descriptor, layerHosting.descriptor, syncDeadline.descriptor, liveResizeDeadline.descriptor, dragResize.descriptor,
         dragResizeDeadline.descriptor, keyResizeTopLeft.descriptor, framesOwnedByCommit.descriptor]
    }
}

/// How a Chromium page follows a pane resize drag (`BrowserResizeTunables.dragResize`).
public nonisolated enum BrowserDragResize: String, Sendable, CaseIterable, TunableChoice {
    /// The page lays out at every frame's size and shows each size when Chromium has drawn it, a few
    /// frames behind the pane (Chromium's AsyncLiveResize: nothing waits for the page).
    case live
    /// The page keeps its drag-start size, top-left anchored and clipped by its pane, and lays out once
    /// when the release lands (`CEFTabContentView.paneResizeGestureDidChange`).
    case hold
    /// Live layout without AsyncLiveResize: Chromium's CATransactionCoordinator holds each app frame that
    /// resized a page until the page drew at the new size, up to its 500 ms `kUIPaintTimeout` (no shorter
    /// deadline before fork API 27). A launch switch (`CEFSwitches`): applies when Chromium next starts.
    case synced
    /// Live layout, and from the drag's first move until its release landed every page over a dragged pane, hosted or
    /// not, holds each app frame for its frame at the new size up to `dragResizeDeadline`, capped at half the shortest
    /// display frame (`CEFResizeSyncDeadline`), so the frame commits by its display link's target time
    /// (`CEFLayerHosting.paneResizeDrag`). Needs fork API 27 (`cmux_browser_set_resize_sync`); below it this is `live`.
    case resizeSync

    /// Live: on the split_resize harness (the three variants back to back on one M4 capture Mac, 2026-10-27) it
    /// lays the page out within half a frame of its pane with the fewest dropped app frames; hold lays out about
    /// 400 ms after the release (Leo, on hold: "still lagging like shit when recalculating size/layout"), and
    /// synced follows as closely but holds more app frames.
    public static let `default` = BrowserDragResize.live

    public var tunableTitle: String {
        switch self {
        case .live: "Live (lays out every frame, behind the divider)"
        case .hold: "Hold (keeps its size, lays out once on release)"
        case .synced: "Synced live (waits for the page; next Chromium start)"
        case .resizeSync: "Resize sync (waits for the page up to half a frame; fork API 27)"
        }
    }
}
