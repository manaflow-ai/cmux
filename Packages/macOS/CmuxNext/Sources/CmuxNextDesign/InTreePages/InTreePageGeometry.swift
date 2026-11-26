public import AppKit
import QuartzCore

/// `debug.layers` `page_views[].geometry`: the in-tree page's views and layers as AppKit and Core Animation hold them,
/// so a check compares where the page draws with where its view is (in-tree-regressions.md bug 13).
///
/// Every view under the container (the page's `WebContentsViewCocoa` and `RenderWidgetHostViewCocoa`) with its frame,
/// bounds and flip, and every layer under each view's layer with its frame, bounds, geometry flip and autoresizing mask;
/// a `CALayerHost` (Chromium's GPU output) adds its context id. Rects are [x, y, w, h] in the parent's coordinates.
/// `fits` is false when a layer that holds the page's pixels (a layer with a `CALayerHost` under it, or one) is not the
/// size of the view that owns it: the page then draws offset in, or short of, its pane.
enum InTreePageGeometry {
    static func report(_ container: NSView) -> [String: Any] {
        var misfits: [[String: Any]] = []
        if let page = InTreePages.viewsPage(of: container) { return viewsReport(container, page: page) }
        let tree = view(container, depth: 0, misfits: &misfits)
        return ["tree": tree, "fits": misfits.isEmpty, "misfits": misfits]
    }

    /// Views window mode: the page is a Views child of the window's widget, outside `container`. `views_window` says
    /// where: the window's runtime class, the page's and the container's rects in the window (the page fits when they
    /// match) and the page's superviews up to the window's slot.
    private static func viewsReport(_ container: NSView, page: NSView) -> [String: Any] {
        var misfits: [[String: Any]] = []
        let tree = view(page, depth: 0, misfits: &misfits)
        let pageRect = page.convert(page.bounds, to: nil)
        let containerRect = container.convert(container.bounds, to: nil)
        if abs(pageRect.minX - containerRect.minX) > 0.5 || abs(pageRect.minY - containerRect.minY) > 0.5
            || abs(pageRect.width - containerRect.width) > 0.5 || abs(pageRect.height - containerRect.height) > 0.5 {
            misfits.append(["owner": "views_page", "page_in_window": rect(pageRect), "container_in_window": rect(containerRect)])
        }
        let chain = sequence(first: page, next: { $0 is ViewsWindowSlotView ? nil : $0.superview }).dropFirst()
            .map { NSStringFromClass(type(of: $0)) }
        let place: [String: Any] = [
            "window_class": container.window.map { NSStringFromClass(type(of: $0)) } ?? "", "superviews": Array(chain),
            "page_in_window": rect(pageRect), "container_in_window": rect(containerRect),
        ]
        return ["tree": tree, "fits": misfits.isEmpty, "misfits": misfits, "views_window": place]
    }

    private static func view(_ view: NSView, depth: Int, misfits: inout [[String: Any]]) -> [String: Any] {
        var out: [String: Any] = [
            "class": NSStringFromClass(type(of: view)), "frame": rect(view.frame), "bounds": rect(view.bounds),
            "flipped": view.isFlipped, "hidden": view.isHidden,
        ]
        if let layer = view.layer {
            out["layer"] = self.layer(layer, owner: view, depth: 0, misfits: &misfits)
        }
        if depth < 4 {
            out["subviews"] = view.subviews.map { self.view($0, depth: depth + 1, misfits: &misfits) }
        }
        return out
    }

    private static func layer(_ layer: CALayer, owner: NSView, depth: Int, misfits: inout [[String: Any]]) -> [String: Any] {
        var out: [String: Any] = [
            "class": NSStringFromClass(type(of: layer)), "frame": rect(layer.frame), "bounds": rect(layer.bounds),
            "geometry_flipped": layer.isGeometryFlipped, "autoresizing": Int(layer.autoresizingMask.rawValue),
            "hidden": layer.isHidden,
        ]
        if !CATransform3DIsIdentity(layer.transform) { out["transform"] = true }
        let hostSelector = NSSelectorFromString("contextId")
        if isLayerHost(layer), layer.responds(to: hostSelector), let id = layer.value(forKey: "contextId") {
            out["context_id"] = id
        }
        // A layer above a CALayerHost (Chromium's flipped container) must cover its view: when it keeps an old size,
        // the page's pixels are pinned to its top, which then sits above or below the view's top.
        if depth > 0, !isLayerHost(layer), hostsPage(layer), let superlayer = layer.superlayer,
           abs(layer.frame.width - superlayer.bounds.width) > 0.5 || abs(layer.frame.height - superlayer.bounds.height) > 0.5
            || abs(layer.frame.minX) > 0.5 || abs(layer.frame.minY) > 0.5 {
            misfits.append(["owner": NSStringFromClass(type(of: owner)), "layer": NSStringFromClass(type(of: layer)),
                            "frame": rect(layer.frame), "superlayer_bounds": rect(superlayer.bounds)])
        }
        if depth < 5 {
            out["sublayers"] = (layer.sublayers ?? []).map { self.layer($0, owner: owner, depth: depth + 1, misfits: &misfits) }
        }
        return out
    }

    private static func isLayerHost(_ layer: CALayer) -> Bool {
        NSStringFromClass(type(of: layer)) == "CALayerHost"
    }

    private static func hostsPage(_ layer: CALayer) -> Bool {
        (layer.sublayers ?? []).contains { isLayerHost($0) || hostsPage($0) }
    }

    private static func rect(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 10).rounded() / 10 }
    }
}

extension InTreePageContainer {
    /// ``InTreePageGeometry/report(_:)`` of this container as JSON text (`debug.layers` `page_views[].geometry`).
    public var inTreeGeometry: String {
        let report = InTreePageGeometry.report(self)
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
