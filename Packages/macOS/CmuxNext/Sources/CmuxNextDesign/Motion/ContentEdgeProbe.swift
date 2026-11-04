#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// How far a window's pane contents (a terminal surface, a Chromium page's host) sit from their pane's content area, at
/// their left and right edges (FRAME OWNER REFACTOR S7, DEBUG and bench builds): from view frames and from the model
/// layers that the next commit sends. A live-resize film shows a terminal or page one step behind its pane's strip; this
/// tells whether the app commits them there (views), whether the layers trail the views, or neither (their pixels come late).
@MainActor
struct ContentEdgeProbe {
    /// The class names of the views measured (the probe lives below the terminal and browser modules).
    var contentClassNames: Set<String> = ["TerminalSurfaceView", "CEFHostView"]

    /// The largest left or right edge distance of a measured view from its pane content area, in points, from view
    /// frames and from model layers; nil when the window shows none.
    func measure(in window: NSWindow) -> (views: Int, view: CGFloat, layer: CGFloat)? {
        guard let content = window.contentView else { return nil }
        let rootLayer = content.superview?.layer ?? content.layer
        var count = 0
        var viewError: CGFloat = 0, layerError: CGFloat = 0
        var stack: [NSView] = [content]
        while let view = stack.popLast() {
            guard !view.isHidden else { continue }
            guard contentClassNames.contains(String(describing: type(of: view))) else {
                stack.append(contentsOf: view.subviews)
                continue
            }
            guard let area = Self.area(of: view) else { continue }
            count += 1
            let shown = view.convert(view.bounds, to: nil), pane = area.convert(area.bounds, to: nil)
            viewError = max(viewError, abs(shown.minX - pane.minX), abs(shown.maxX - pane.maxX))
            if let rootLayer, let layer = view.layer, let areaLayer = area.layer {
                // The x axis is the same in every layer's space (a flip is vertical).
                let shownLayer = layer.convert(layer.bounds, to: rootLayer), paneLayer = areaLayer.convert(areaLayer.bounds, to: rootLayer)
                layerError = max(layerError, abs(shownLayer.minX - paneLayer.minX), abs(shownLayer.maxX - paneLayer.maxX))
            }
        }
        return count == 0 ? nil : (count, viewError, layerError)
    }

    /// The nearest pane content area above `view`.
    static func area(of view: NSView) -> PaneContentAreaView? {
        var next = view.superview
        while let current = next {
            if let area = current as? PaneContentAreaView { return area }
            next = current.superview
        }
        return nil
    }
}
#endif
