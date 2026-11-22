public import AppKit
import CmuxNextDesign

/// A toolbar control whose hover follows the pointer (`OmnibarPointer`).
@MainActor
protocol PointerHoverReporting: NSView {
    var isPointerHovering: Bool { get }
}

extension ChromeIconButton: PointerHoverReporting {
    var isPointerHovering: Bool { isHovering }
}

extension OmnibarPillView: PointerHoverReporting {
    var isPointerHovering: Bool { debugHovering }
}

/// What `debug.omnibar` reports about the pointer over the browser toolbar
/// (`OmnibarPointer`, the live check `omnibar-pointer-live.py`): which
/// controls show hover, the region and cursor the rules give at a probe
/// point, and where the parts are, in window points from the top left
/// (the coordinates `debug.mouse` takes).
public struct BrowserPointerDebug: Sendable, Equatable {
    /// The omnibar's own hover lift.
    public var barHovering: Bool
    /// Identifiers of the toolbar buttons that show hover now.
    public var hoveredButtons: [String]
    /// The region (`text`, `bar`, `barEdge`, `control`, `toolbar`, `outside`) and the
    /// cursor (`arrow`, `iBeam`) at the probe point.
    public var probeRegion: String?
    public var probeCursor: String?
    /// The cursor the field last installed over its text when AppKit rebuilt
    /// its cursor rects (`arrow`, `iBeam`); nil before the first build.
    /// AppKit rebuilds them lazily for the key window, so this can lag in a
    /// window that is never key.
    public var installedTextCursor: String?
    /// The cursor the toolbar row last set on a pointer move (`arrow`,
    /// `iBeam`); nil before the first move. The row sets it in any window
    /// state, also while a Chromium page window has the key.
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
        // The bar's resolved look (cx-d0d.101): fill RGBA, radius, ring, state, coverage.
        object["bar_style"] = addressBar.pill.debugStyle
        #if DEBUG
        object["omnibar_trace"] = addressBar.controller.trace
        // `ArrowCursorView.pointerDidMove` past its first check: calls and their mean cost.
        object["move_hook"] = ["calls": MoveHookStats.calls,
                               "mean_ns": MoveHookStats.calls == 0 ? 0 : Double(MoveHookStats.totalNanoseconds) / Double(MoveHookStats.calls)] as [String: Any]
        #endif
        object["frames"] = report.frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
        return object
    }

    /// The pointer report; `probe` is a window point from the top left.
    public func debugPointer(probe: CGPoint?) -> BrowserPointerDebug {
        var hovered: [String] = []
        var stack: [NSView] = [toolbar]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard let control = view as? any PointerHoverReporting, !(view is OmnibarPillView), control.isPointerHovering else { continue }
            let id = view.accessibilityIdentifier()
            hovered.append(id.isEmpty ? String(describing: type(of: view)) : id)
        }
        var frames: [String: CGRect] = [:]
        func record(_ name: String, _ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor, let rect = topLeftFrame(of: view) else { return }
            frames[name] = rect
        }
        record("toolbar", toolbar)
        record("bar", addressBar)
        record("text", addressBar.field)
        if let window, let content = window.contentView, !addressBar.isHiddenOrHasHiddenAncestor {
            let rect = addressBar.convert(addressBar.textArea, to: nil)
            frames["text_area"] = CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        record("star", addressBar.starButton)
        record("chip", addressBar.pageInfoAnchor)
        for button in [backButton, forwardButton, reloadButton] { record(button.accessibilityIdentifier(), button) }
        for button in BrowserToolbarButton.allCases {
            if let view = toolbarButtons.button(button) { record(button.identifier, view) }
        }
        let probed = probe.flatMap(region(atTopLeft:))
        return BrowserPointerDebug(
            barHovering: addressBar.pill.debugHovering,
            hoveredButtons: hovered.sorted(),
            probeRegion: probed?.rawValue ?? (probe == nil ? nil : "outside"),
            probeCursor: probed.map { OmnibarPointer.cursor($0).rawValue },
            installedTextCursor: addressBar.field.installedCursor?.rawValue,
            trackedCursor: toolbar.trackedCursor?.rawValue,
            frames: frames
        )
    }

    private func topLeftFrame(of view: NSView) -> CGRect? {
        guard let window, let content = window.contentView else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The region the cursor rules see at a window point from the top left:
    /// the view AppKit hits there, classified.
    private func region(atTopLeft point: CGPoint) -> OmnibarPointer.Region? {
        guard let window, let content = window.contentView else { return nil }
        let base = NSPoint(x: point.x, y: content.bounds.height - point.y)
        // hitTest takes a point in the receiver's superview coordinates.
        let root = content.superview ?? content
        guard let hit = root.hitTest(root.convert(base, from: nil)), hit.isDescendant(of: toolbar) else { return nil }
        let field = addressBar.field
        if hit === field || hit.isDescendant(of: field) { return .text }
        if hit === addressBar || hit.superview === addressBar && hit is NSStackView {
            return addressBar.textArea.contains(addressBar.convert(base, from: nil)) ? .bar : .barEdge
        }
        if OmnibarPointer.clickable(at: hit, below: toolbar) != nil { return .button }
        var view: NSView? = hit
        while let current = view, current !== toolbar {
            if current is NSControl || current is any PointerHoverReporting || current is ProfileBadgeView || current is MachineBadgeView {
                return .control
            }
            view = current.superview
        }
        return .toolbar
    }
}
