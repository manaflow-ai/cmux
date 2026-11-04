#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import IOSurface

/// How far a window's pane contents (a terminal surface, a Chromium page's host) sit from their pane, at their left and
/// right edges, in the state the next commit sends (FRAME OWNER REFACTOR S7, DEBUG and bench builds). A live-resize film
/// shows a terminal or page one step behind its pane's strip; this tells whether the app commits them there (views),
/// whether the layers trail the views, or neither (their pixels or their page window come late).
@MainActor
struct ContentEdgeProbe {
    /// The class names of the views measured (the probe lives below the terminal, browser and layout modules).
    var contentClassNames: Set<String> = ["TerminalSurfaceView", "CEFHostView"]
    /// The pane's clip view (its padded content rect: the pane edge a film measures) and its tab strip.
    var paneClassName = "PaneClipView"
    var stripClassName = "TabStripView"
    /// The pane content a Chromium page window sits over (its host).
    var pageHostClassName = "CEFHostView"

    /// Each value is the largest over the measured views, in points (pixels for `pixelLag`), 0 when nothing to measure.
    struct Reading: Equatable {
        var views = 0
        /// Against the pane content area (``PaneContentAreaView``): view frames, then model layers.
        var area: CGFloat = 0, areaLayer: CGFloat = 0
        /// Against the pane's clip view, left and right edges, in window coordinates.
        var pane: CGFloat = 0, paneLayer: CGFloat = 0
        /// Against the pane's tab strip, left edge only (the strip ends before the pane's tools).
        var strip: CGFloat = 0, stripLayer: CGFloat = 0
        /// A terminal's shown IOSurface against its layer's size in pixels (a frame drawn at another size).
        var pixelLag: CGFloat = 0
        /// Each shown page host against the page window nearest it, all four edges, on screen (a page window with no
        /// shown host, such as the parked New Tab page, counts nothing).
        var pageWindow: CGFloat = 0
    }

    func measure(in window: NSWindow) -> Reading? {
        guard let content = window.contentView else { return nil }
        let rootLayer = content.superview?.layer ?? content.layer
        var reading = Reading()
        var pageHosts: [CGRect] = []
        var stack: [NSView] = [content]
        while let view = stack.popLast() {
            guard !view.isHidden else { continue }
            let name = String(describing: type(of: view))
            guard contentClassNames.contains(name) else {
                stack.append(contentsOf: view.subviews)
                continue
            }
            reading.views += 1
            let shown = view.convert(view.bounds, to: nil)
            if name == pageHostClassName { pageHosts.append(window.convertToScreen(shown)) }
            let shownLayer = rootLayer.flatMap { root in view.layer.map { $0.convert($0.bounds, to: root) } }
            func compare(_ other: NSView?, bothEdges: Bool, _ viewError: inout CGFloat, _ layerError: inout CGFloat) {
                guard let other else { return }
                let rect = other.convert(other.bounds, to: nil)
                viewError = max(viewError, abs(shown.minX - rect.minX), bothEdges ? abs(shown.maxX - rect.maxX) : 0)
                // The x axis is the same in every layer's space (a flip is vertical).
                if let shownLayer, let root = rootLayer, let layer = other.layer {
                    let otherLayer = layer.convert(layer.bounds, to: root)
                    layerError = max(layerError, abs(shownLayer.minX - otherLayer.minX), bothEdges ? abs(shownLayer.maxX - otherLayer.maxX) : 0)
                }
            }
            compare(Self.ancestor(of: view) { $0 is PaneContentAreaView }, bothEdges: true, &reading.area, &reading.areaLayer)
            let pane = Self.ancestor(of: view) { String(describing: type(of: $0)) == paneClassName }
            compare(pane, bothEdges: true, &reading.pane, &reading.paneLayer)
            compare(pane.flatMap { Self.descendant(of: $0, named: stripClassName) }, bothEdges: false, &reading.strip, &reading.stripLayer)
            if let layer = view.layer, let contents = layer.contents {
                let object = contents as CFTypeRef
                if CFGetTypeID(object) == IOSurfaceGetTypeID() {
                    let surface = unsafeDowncast(object, to: IOSurface.self)
                    let scale = layer.contentsScale
                    reading.pixelLag = max(reading.pixelLag, abs(CGFloat(surface.width) - layer.bounds.width * scale),
                                           abs(CGFloat(surface.height) - layer.bounds.height * scale))
                }
            }
        }
        // A host against the nearest page window only: rounded out to whole points, a page window overlaps the content beside
        // its host, and a parked one has no shown host.
        let pages = pageHosts.isEmpty ? [] : PageWindowMoves.pages(of: window).map(\.frame)
        for host in pageHosts {
            guard let nearest = pages.map({ PageWindowMoves.edgeDistance($0, host) }).min() else { continue }
            reading.pageWindow = max(reading.pageWindow, nearest)
        }
        return reading.views == 0 ? nil : reading
    }

    /// The nearest view above `view` that `matches`.
    static func ancestor(of view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        var next = view.superview
        while let current = next {
            if matches(current) { return current }
            next = current.superview
        }
        return nil
    }

    /// The first shown view under `root` of class `name` (breadth first).
    static func descendant(of root: NSView, named name: String) -> NSView? {
        var queue = root.subviews[...]
        while let view = queue.popFirst() {
            if !view.isHidden, String(describing: type(of: view)) == name { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
#endif
