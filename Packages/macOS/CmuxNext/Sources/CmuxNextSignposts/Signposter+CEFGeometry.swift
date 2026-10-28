import CmuxNextTrace
import os

// The `cef.geometry` and `cef.host_input` points (p09-observability task 038, perf-hot `cef-geometry` and
// `cef-host-input`; owner PL-motion-cef). `cef.geometry` is one thread slice (B/E) per parent window geometry change
// or divider catcher sync (`WindowOverlayLayer`), with one instant (I) per geometry post a page view makes inside it,
// like Chrome's `TRACE_EVENT0("ui", "RenderWidgetHostViewMac::SetBounds")` around a view move
// (content/browser/renderer_host/render_widget_host_view_mac.mm). `cef.host_input` is one instant per input frame
// (mouse, wheel, key, edit command, IME text) written to the Chromium host, like Chrome's
// `RenderWidgetHostImpl::ForwardInputEvent` marks (content/browser/renderer_host/render_widget_host_impl.cc).
//
// Both fire per display frame or per input event, so the ring takes them only while a recording-only category is
// on too, never in the black box (`TraceCategories.blackBox` fires at most once per action), as `cef.pump` does.
// Not mirrored to MetricKit. The log system formats the fields only when something reads them.
nonisolated extension Signposter {
    /// The recording-only category a ring record of ``SignpostName/cefGeometry`` also needs on: a live resize or a
    /// spring writes one slice per tick and one instant per page per frame. `motion` is layout motion, off in the
    /// black box.
    static let cefGeometryRecordingCategory = SignpostCategory.motion

    /// The recording-only category a ring record of ``SignpostName/cefHostInput`` also needs on: one per pointer
    /// move or wheel step. `input` is input other than a key-down, off in the black box and never uploaded.
    static let cefHostInputRecordingCategory = SignpostCategory.input

    /// What a ``SignpostName/cefGeometry`` slice re-places: its code in the begin record's `arg0`. Fixed and
    /// nonzero, so rings written by an older build decode with the same numbers.
    public nonisolated enum CEFGeometrySource: UInt64, Sendable {
        /// The parent window moved or resized: the overlay panel, the catchers and every changed page follow.
        case parentGeometry = 1
        /// Only the divider catcher panels re-synced (placement, divider areas or a blocking overlay changed).
        case catcherSync = 2
    }

    /// The input frames a ``SignpostName/cefHostInput`` instant marks. The raw value is the frame's kind on the
    /// Chromium host wire (`ChromiumHostFrame.Kind`), the ring's `arg0`. Navigation, geometry, focus, ping, stats
    /// and quit frames are not input and record nothing.
    public nonisolated enum CEFHostInputKind: UInt32, Sendable, CaseIterable {
        /// A mouse button or move.
        case mouse = 3
        /// A scroll wheel or trackpad step.
        case wheel = 4
        /// A key press.
        case key = 5
        /// An edit command from a key equivalent (copy, cut, paste, select all, undo, redo).
        case edit = 10
        /// An IME composition or commit (marked text, inserted text).
        case ime = 11

        /// Whether the frame's time is a keystroke's: the keystroke-timing gate (task 128) drops its instant.
        public var carriesKeyTiming: Bool {
            switch self {
            case .key, .edit, .ime: true
            case .mouse, .wheel: false
            }
        }
    }

    /// Begins a ``SignpostName/cefGeometry`` slice (`source=<code>`). The ring's B, written only while both `cef` and
    /// ``cefGeometryRecordingCategory`` are on, holds the source's code in `arg0`. End it on this thread with
    /// ``endCEFGeometry(_:catchers:panelMoves:)``.
    ///
    /// - Parameter source: What the slice re-places.
    /// - Returns: The state to pass to ``endCEFGeometry(_:catchers:panelMoves:)``.
    public func beginCEFGeometry(_ source: CEFGeometrySource) -> SignpostInterval {
        let code = source.rawValue
        return openInterval(.cefGeometry, arg0: code,
                            traced: trace.isEnabled(categoryBit: Self.cefGeometryRecordingCategory.traceBit)) {
            signposter.beginInterval(SignpostName.cefGeometry.staticName, id: $0, "source=\(code, privacy: .public)")
        }
    }

    /// Ends a ``SignpostName/cefGeometry`` slice begun with ``beginCEFGeometry(_:)``: the log system's end carries
    /// `catchers=<shown> moves=<panel moves>`, and the ring's E (written exactly when the B was) holds the catcher
    /// panels shown in `arg0` and the catcher panels made or re-framed in the slice in `arg1`.
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
    /// re-places one page window. The ring's I (only while ``cefGeometryRecordingCategory`` is on too) holds
    /// nothing else.
    public func cefGeometryPost() {
        signposter.emitEvent(SignpostName.cefGeometry.staticName)
        guard trace.isEnabled(categoryBit: Self.cefGeometryRecordingCategory.traceBit) else { return }
        trace.event(.cefGeometry, arg0: 0)
    }

    /// Records one ``SignpostName/cefHostInput`` instant (`kind=<wire kind>`): an input frame written to the
    /// Chromium host. The ring's I (only while ``cefHostInputRecordingCategory`` is on too) holds the frame's wire
    /// kind in `arg0`, never the event's contents. While the keystroke-timing gate is closed
    /// (``TraceRuntime/isKeyTimingSuppressed``, task 128), a kind that ``CEFHostInputKind/carriesKeyTiming`` records
    /// nothing, in the log system either, as `key.*` does.
    ///
    /// - Parameter kind: The input frame's kind.
    public func cefHostInput(_ kind: CEFHostInputKind) {
        guard !kind.carriesKeyTiming || !trace.isKeyTimingSuppressed else { return }
        let wire = kind.rawValue
        signposter.emitEvent(SignpostName.cefHostInput.staticName, "kind=\(wire, privacy: .public)")
        guard trace.isEnabled(categoryBit: Self.cefHostInputRecordingCategory.traceBit) else { return }
        trace.event(.cefHostInput, arg0: UInt64(wire))
    }
}
