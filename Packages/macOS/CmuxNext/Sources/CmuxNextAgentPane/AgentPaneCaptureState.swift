#if DEBUG || CMUX_BENCH_HOOKS
/// Whether an agent pane has reached a painted engine that a window snapshot can draw.
public struct AgentPaneCaptureState: Sendable {
    /// The pane is attached, painted and drawable on its final engine.
    public let ready: Bool

    /// The observed engine and paint signals, included when a scene fails to settle.
    public let diagnostic: String

    /// Evaluates capture readiness without depending on a live page or app.
    ///
    /// A starting Chromium host leaves its backing WebKit view hidden and idle. It must not
    /// settle until Chromium attaches and paints, or falls back to WebKit. Chromium then needs
    /// snapshot eligibility; WebKit needs completed navigation before fixture rows are seeded.
    ///
    /// - Parameters:
    ///   - attached: Whether the backing view belongs to a window.
    ///   - loading: Whether WebKit is still navigating.
    ///   - chromium: Whether the pane currently shows Chromium.
    ///   - chromiumStarting: Whether Chromium is requested but has not attached.
    ///   - chromiumShown: Whether the window snapshot can draw this Chromium page.
    ///   - painted: Whether both the document and agent content have painted.
    public init(attached: Bool, loading: Bool, chromium: Bool, chromiumStarting: Bool,
                chromiumShown: Bool, painted: Bool) {
        ready = attached && painted && !chromiumStarting && (chromium ? chromiumShown : !loading)
        diagnostic = "inWindow=\(attached),loading=\(loading),chromium=\(chromium),starting=\(chromiumStarting),shown=\(chromiumShown),painted=\(painted)"
    }
}
#endif
