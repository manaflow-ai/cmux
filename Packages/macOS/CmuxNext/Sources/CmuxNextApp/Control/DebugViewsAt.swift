#if DEBUG
import AppKit
import CmuxNextSettings

/// `debug.views_at {x, y}` (DEBUG builds): every view of the main window whose frame contains the point (window points
/// from the top left), deepest last, each with its class, frame in the window, hidden and alpha, its layer's
/// `zPosition`, `masksToBounds`, mask, background and animation keys, and the layer's presentation frame. For a region
/// that shows the wrong thing (a zoomed pane that stayed dark at its old left edge): which view and layer is on top
/// there, and whether a move or a mask is still on it.
@MainActor
enum DebugViewsAt {
    static func report(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let window = services.windows.controllers.first?.window, let root = window.contentView else {
            return .object(["error": .string("no window")])
        }
        let x = params["x"]?.doubleValue ?? 0, y = params["y"]?.doubleValue ?? 0
        let point = NSPoint(x: x, y: window.frame.height - y)
        var rows: [JSONValue] = []
        func walk(_ view: NSView, depth: Int) {
            let inWindow = view.convert(view.bounds, to: nil)
            guard inWindow.contains(point), rows.count < 200 else { return }
            let layer = view.layer
            func rect(_ r: CGRect) -> JSONValue {
                .array([r.minX, window.frame.height - r.maxY, r.width, r.height].map { .number(Double($0)) })
            }
            var row: [String: JSONValue] = [
                "depth": .number(Double(depth)), "class": .string(String(describing: type(of: view))),
                "frame": rect(inWindow), "hidden": .bool(view.isHidden), "alpha": .number(Double(view.alphaValue)),
            ]
            if let layer {
                row["z"] = .number(Double(layer.zPosition))
                row["masks"] = .bool(layer.masksToBounds)
                row["mask"] = .bool(layer.mask != nil)
                row["opaque_bg"] = .bool((layer.backgroundColor?.alpha ?? 0) >= 1)
                row["animations"] = .array((layer.animationKeys() ?? []).map { .string($0) })
                if let presented = layer.presentation(), let superlayer = layer.superlayer {
                    row["presented"] = rect(superlayer.convert(presented.frame, to: root.layer))
                }
                row["sublayers"] = .number(Double(layer.sublayers?.count ?? 0))
            }
            rows.append(.object(row))
            guard !view.isHidden else { return }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return .object(["point": .array([.number(x), .number(y)]), "views": .array(rows)])
    }
}
#endif
