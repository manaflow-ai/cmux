/// How fast a page renders in WebKit (``PageEngineOptions/renderRate``).
///
/// WebKit's own default renders a page at the display-rate divisor nearest 60 fps (60 on a
/// 120 Hz display), so a page that does not ask for the full rate runs its main-thread rendering
/// (scroll handlers, `requestAnimationFrame`, rows a virtual list mounts, JS-driven fades) every
/// other refresh. Async scrolling, sticky layers and scrollbars move on WebKit's scrolling thread
/// at the display's rate either way. A Chromium page has no WebKit rate and ignores this.
public nonisolated enum PageRenderRate: Sendable, Equatable {
    /// The display's full rate, and near 60 fps in Low Power Mode, following Low Power Mode when
    /// it changes: the same rule as browser tabs (`WebKitRenderRate.prefersFullRate`). Every
    /// page's default.
    case display
    /// Always the display's full rate, whatever Low Power Mode says; the page's owner changes it
    /// itself (the agent pane's full and adaptive rates).
    case full
    /// WebKit's rate nearest 60 fps (the agent pane's debug `capped` rate).
    case capped
}
