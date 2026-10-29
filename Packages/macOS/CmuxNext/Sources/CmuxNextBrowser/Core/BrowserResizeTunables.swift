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

    /// The developer's local override of the feature `cefLayerHosting`
    /// (`schemas/features/features.d/cefLayerHosting.json`, which `replaces`
    /// this key): nothing reads it as a tunable. On DEV and NIGHTLY the App
    /// reads it from the build's debug-tunables.json at launch, and the
    /// launch's `FeatureList` takes it as the feature's local override (step 3,
    /// source `local`: under managed policy and
    /// `CMUX_DISABLE_FEATURES`/`CMUX_ENABLE_FEATURES`), so a change applies at
    /// the next launch. Set: the feature takes this value; a pane's page then
    /// hosts only where the app makes every Track A call (`CEFLayerHosting.TrackA`).
    public static let layerHosting = Tunable<Bool>.toggle(
        "browserResize.layerHosting", section, "Host Chromium pages in the window's layers",
        help: "Overrides the feature cefLayerHosting: a Chromium pane page draws inside the cmux window's own layer tree where the app makes every Track A call for the fork (resize fence, embedder visibility); DevTools and popups keep their own window. Applies at the next launch.",
        default: false, code: "BrowserResizeTunables.layerHosting")

    /// The local override of the bench-only feature `cefLayerHostingEveryPage`
    /// (`features.d/cefLayerHostingEveryPage.json` `replaces` it), read the same
    /// way as `layerHosting`: the layer hosting benches' on arm
    /// (`cef-layer-verify.py --mode on`). Set: every page window from fork API 26
    /// hosts, DevTools and popups too, without the Track A calls. DEBUG and bench
    /// builds only (the feature is compiled out of the others).
    public static let layerHostingEveryPage = Tunable<Bool>.toggle(
        "browserResize.layerHostingEveryPage", section, "Host every Chromium page window (bench arm)",
        help: "Overrides the bench-only feature cefLayerHostingEveryPage: every Chromium page window, DevTools and popups too, draws inside the cmux window's own layer tree from fork API 26, without the Track A calls. Debug and bench builds only. Applies at the next launch.",
        default: false, code: "BrowserResizeTunables.layerHostingEveryPage")

    /// While a page is layer hosted (feature `cefLayerHosting`), how long a resize of
    /// its pane may hold the window's frame for Chromium's frame at the new
    /// size (fork API 27 to 31; from API 32 it has no effect), so the page
    /// resizes in the same frame as the pane.
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
    /// API 27 to 31, no effect from API 32; Chromium itself waited up to
    /// 500 ms), under the same cap as `syncDeadline` (half the shortest
    /// display frame). 0 never waits.
    public static let liveResizeDeadline = Tunable<Double>.number(
        "browserResize.liveResizeDeadline", section, "Page wait during window resize",
        help: "While the window is resized, how long each Chromium page may hold a frame to draw at the new size, so it resizes with the window. Never more than half the shortest display frame. 0 never waits; the page then shows its last frame until it draws.",
        default: 0.016, range: 0...0.1, step: 0.001, unit: .seconds, code: "BrowserResizeTunables.liveResizeDeadline")

    /// With the `pageSpringResizeOnce` feature, how a page resizes while its pane springs: `once` (the
    /// default) at the spring's start, held at its top-left; `perFrame` on every frame, to compare.
    public static let springPageResize = Tunable<SpringPageResize>.choice(
        "browserResize.springPageResize", section, "Page resize in pane springs",
        help: "With the pageSpringResizeOnce feature on, how a page resizes while its pane springs: once at the spring's start (default), held at its top-left with the page color beside it, or on every frame, to compare.",
        default: .once, code: "BrowserResizeTunables.springPageResize")

    /// How a Chromium page follows a pane divider or a column or row edge a person drags
    /// (Leo, 2026-10-26: "resizing the panes it propagates so fucking slowly to the right side browser tab
    /// thing"). Chromium draws in another process, so a page laid out at every frame's size shows each size
    /// some frames after its pane. `BrowserDragResize` names the three ways; the default is the one the
    /// split_resize harness measured to follow the drag best (`BrowserDragResize.default`).
    public static let dragResize = Tunable<BrowserDragResize>.choice(
        "browserResize.dragResize", section, "Page while a divider is dragged",
        help: "Live: the page lays out at every size, a few frames behind the divider. Hold: the page keeps its size and moves with the pane, clipped, and lays out once when the drag lands. Synced live: Chromium holds each app frame until the page has drawn at the new size (up to 500 ms); applies the next time Chromium starts.",
        default: BrowserDragResize.default, code: "BrowserResizeTunables.dragResize")

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
        [pageBackdrop.descriptor, layerHosting.descriptor, layerHostingEveryPage.descriptor, syncDeadline.descriptor,
         liveResizeDeadline.descriptor, springPageResize.descriptor, dragResize.descriptor]
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
        }
    }
}
