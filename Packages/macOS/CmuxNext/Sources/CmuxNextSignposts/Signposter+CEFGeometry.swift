import CmuxNextTrace
import os

// The `cef.geometry` and `cef.host_input` points (p09-observability task 038, perf-hot `cef-geometry` and
// `cef-host-input`; owner PL-motion-cef). `cef.geometry` is one thread slice (B/E) per parent geometry change or
// divider catcher sync of a window with Chromium pages, with one instant (I) per geometry post a page view makes
// inside it, like Chrome's `TRACE_EVENT0("ui", "RenderWidgetHostViewMac::SetBounds")` around a view move and its
// `TRACE_EVENT_INSTANT` marks (content/browser/renderer_host/render_widget_host_view_mac.mm). `cef.host_input` is
// one instant per input frame written to the Chromium host, like Chrome's `RenderWidgetHostImpl::ForwardInputEvent`
// marks (content/browser/renderer_host/render_widget_host_impl.cc). Not mirrored to MetricKit. The fields are
// formatted by the log system only when something reads them, so no point builds a `String`.
nonisolated extension Signposter {
    /// What a ``SignpostName/cefGeometry`` slice re-places: its code in the begin record's `arg0`. Fixed and
    /// nonzero, so rings written by an older build decode with the same numbers.
    public nonisolated enum CEFGeometrySource: UInt64, Sendable {
        /// The parent window moved or resized: the overlay panel, the catchers and every changed page follow.
        case parentGeometry = 1
        /// Only the divider catcher panels re-synced (placement, divider areas or a blocking overlay changed).
        case catcherSync = 2
    }

    /// Begins a ``SignpostName/cefGeometry`` slice (`source=<code>`). The ring's B holds the source's code in
    /// `arg0`. End it on this thread with ``endCEFGeometry(_:catchers:panelMoves:)``.
    ///
    /// - Parameter source: What the slice re-places.
    /// - Returns: The state to pass to ``endCEFGeometry(_:catchers:panelMoves:)``.
    public func beginCEFGeometry(_ source: CEFGeometrySource) -> SignpostInterval {
        let code = source.rawValue
        return openInterval(.cefGeometry, arg0: code) {
            signposter.beginInterval(SignpostName.cefGeometry.staticName, id: $0, "source=\(code, privacy: .public)")
        }
    }

    /// Ends a ``SignpostName/cefGeometry`` slice begun with ``beginCEFGeometry(_:)``: the log system's end carries
    /// `catchers=<shown> moves=<panel moves>`, and the ring's E holds the catcher panels shown in `arg0` and the
    /// window-server moves of catcher panels the slice made (panels made or re-framed) in `arg1`.
    ///
    /// - Parameters:
    ///   - interval: The state ``beginCEFGeometry(_:)`` returned.
    ///   - catchers: The divider catcher panels shown when the slice ends.
    ///   - panelMoves: The catcher panels made or re-framed inside the slice.
    public func endCEFGeometry(_ interval: SignpostInterval, catchers: Int, panelMoves: Int) {
        let name = SignpostName.cefGeometry
        let shown = UInt64(max(catchers, 0))
        let moves = UInt64(max(panelMoves, 0))
        signposter.endInterval(name.staticName, interval.state,
                               "catchers=\(shown, privacy: .public) moves=\(moves, privacy: .public)")
        if let id = interval.metricKitID { mirror.end(name, id: id) }
        closeInterval(name, interval, arg0: shown, arg1: moves)
    }

    /// Records one ``SignpostName/cefGeometry`` instant: a page view told the fork its geometry changed, so the fork
    /// re-places one page window. The ring's I holds nothing else.
    public func cefGeometryPost() {
        signposter.emitEvent(SignpostName.cefGeometry.staticName)
        trace.event(.cefGeometry, arg0: 0)
    }

    /// Records one ``SignpostName/cefHostInput`` instant (`kind=<kind>`): a frame written to the Chromium host.
    /// The ring's I holds the frame's raw wire kind in `arg0`, never the event's contents. A key frame is dropped
    /// while the keystroke-timing gate is closed (``TraceRuntime/isKeyTimingSuppressed``, task 128), as `key.*` is.
    ///
    /// - Parameters:
    ///   - kind: The frame's raw kind on the wire (`ChromiumHostFrame.Kind`).
    ///   - isKey: The frame carries a key press (its time is a keystroke's).
    public func cefHostInput(kind: UInt32, isKey: Bool) {
        guard !isKey || !trace.isKeyTimingSuppressed else { return }
        signposter.emitEvent(SignpostName.cefHostInput.staticName, "kind=\(kind, privacy: .public)")
        trace.event(.cefHostInput, arg0: UInt64(kind))
    }
}
