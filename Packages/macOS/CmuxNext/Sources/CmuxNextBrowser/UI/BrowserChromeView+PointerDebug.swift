public import AppKit
import CmuxNextDesign

/// What `debug.omnibar` reports about the pointer over the browser toolbar (`OmnibarPointer`): the
/// region and cursor the rules give at a probe point, the cursor the row set last, and where the
/// parts are, in window points from the top left (the coordinates `debug.mouse` takes). Hover is the
/// toolbar page's own (CSS); the page's controls report no hover here.
public struct BrowserPointerDebug: Sendable, Equatable {
    /// The omnibar's own hover lift (drawn by the page; always false here).
    public var barHovering: Bool
    /// Identifiers of the toolbar buttons that show hover now (drawn by the page; empty here).
    public var hoveredButtons: [String]
    /// The region (`bar`, `barEdge`, `button`, `toolbar`, `outside`) and the cursor (`arrow`,
    /// `iBeam`) at the probe point.
    public var probeRegion: String?
    public var probeCursor: String?
    /// The cursor the field installed over its text (the page's CSS; nil here).
    public var installedTextCursor: String?
    /// The cursor the toolbar row last set on a pointer move (`arrow`, `iBeam`); nil before the
    /// first move. The row sets it in any window state, also while a Chromium page window has the key.
    public var trackedCursor: String?
    /// Part name to frame (x, y, width, height).
    public var frames: [String: CGRect]
}

extension BrowserChromeView {
    /// `debug.omnibar`'s `pointer` object as Foundation values (JSON-ready):
    /// `probeX`,`probeY` are a window point from the top left, as `debug.mouse` takes.
    public func debugPointerObject(probeX: Double?, probeY: Double?) -> [String: Any] {
        let report = debugPointer(probe: probeX.flatMap { x in probeY.map { CGPoint(x: x, y: $0) } })
        var object: [String: Any] = ["bar_hovering": report.barHovering, "hovered_buttons": report.hoveredButtons]
        object["probe_region"] = report.probeRegion ?? NSNull()
        object["probe_cursor"] = report.probeCursor ?? NSNull()
        object["installed_text_cursor"] = report.installedTextCursor ?? NSNull()
        object["tracked_cursor"] = report.trackedCursor ?? NSNull()
        #if DEBUG
        // `ArrowCursorView.pointerDidMove` past its first check: calls and their mean cost.
        object["move_hook"] = ["calls": MoveHookStats.calls,
                               "mean_ns": MoveHookStats.calls == 0 ? 0 : Double(MoveHookStats.totalNanoseconds) / Double(MoveHookStats.calls)] as [String: Any]
        #endif
        object["frames"] = report.frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
        return object
    }

    /// The pointer report; `probe` is a window point from the top left.
    public func debugPointer(probe: CGPoint?) -> BrowserPointerDebug {
        var frames: [String: CGRect] = [:]
        if let rect = topLeftFrame(of: toolbar) { frames["toolbar"] = rect }
        let names = ["omnibar": "bar", "text": "text_area", "star": "star", "chip": "chip",
                     "back": BrowserChromeView.backIdentifier, "forward": BrowserChromeView.forwardIdentifier,
                     "reload": BrowserChromeView.reloadIdentifier]
        for key in addressBar.layoutReport.rects.keys {
            guard let anchor = addressBar.anchor(key), let rect = topLeftFrame(of: anchor) else { continue }
            let button = key.hasPrefix("button:") ? BrowserToolbarButton(rawValue: String(key.dropFirst("button:".count))) : nil
            frames[button?.identifier ?? names[key] ?? key] = rect
        }
        let probed = probe.flatMap(region(atTopLeft:))
        return BrowserPointerDebug(
            barHovering: false, hoveredButtons: [],
            probeRegion: probed?.rawValue ?? (probe == nil ? nil : "outside"),
            probeCursor: probed.map { OmnibarPointer.cursor($0).rawValue },
            installedTextCursor: nil,
            trackedCursor: toolbar.trackedCursor?.rawValue,
            frames: frames
        )
    }

    private func topLeftFrame(of view: NSView) -> CGRect? {
        guard let window, let content = window.contentView, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The region the cursor rules see at a window point from the top left, from the page's layout.
    private func region(atTopLeft point: CGPoint) -> OmnibarPointer.Region? {
        guard let window, let content = window.contentView else { return nil }
        let base = NSPoint(x: point.x, y: content.bounds.height - point.y)
        let local = addressBar.convert(base, from: nil)
        guard addressBar.bounds.contains(local), !toolbar.isHiddenOrHasHiddenAncestor else { return nil }
        let rects = addressBar.layoutReport.rects
        if rects["text"]?.contains(local) == true { return .bar }
        if rects.contains(where: { ($0.key.hasPrefix("button:") || $0.key.hasPrefix("action:") || ["back", "forward", "reload", "extensions"].contains($0.key))
            && $0.value.contains(local) }) { return .button }
        if rects["omnibar"]?.contains(local) == true { return .barEdge }
        return .toolbar
    }
}
