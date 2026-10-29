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

    public static var all: [TunableDescriptor] {
        [pageBackdrop.descriptor, layerHosting.descriptor, syncDeadline.descriptor, liveResizeDeadline.descriptor,
         springPageResize.descriptor]
    }
}
