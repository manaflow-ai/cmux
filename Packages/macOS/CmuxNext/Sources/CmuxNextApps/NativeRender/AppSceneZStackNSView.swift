import AppKit

/// `ZStack`: its children layered in order (the last on top), each centered in the stack. The stack
/// is as wide as its widest child (it fills when one fills) and as high as its highest. A child with
/// `position` (`{x, y}` in points, or with `unit: "fraction"` 0...1 of the stack) has its center
/// placed there instead, as SwiftUI's `.position`; an axis it leaves out stays centered. Placed
/// children do not size the stack (a calendar's hour grid sizes it; its events and now line sit on it).
final class AppSceneZStackNSView: AppSceneNodeNSView {
    private var sizing: [AppSceneNodeNSView] { childViews.filter { Self.position(of: $0.node) == nil } }

    override var contentNaturalWidth: CGFloat? {
        var widest: CGFloat = 0
        for child in sizing {
            guard let width = child.naturalWidth else { return nil }
            widest = max(widest, width)
        }
        return widest
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        sizing.map { $0.height(width: min($0.naturalWidth ?? width, width)) }.max() ?? 0
    }

    override func layoutContent(in rect: CGRect) {
        for child in childViews {
            let width = min(child.naturalWidth ?? rect.width, rect.width)
            let height = child.height(width: width)
            let center = Self.position(of: child.node)?.center(in: rect) ?? CGPoint(x: rect.midX, y: rect.midY)
            child.frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height).integral
        }
    }

    /// A child's `position`, or nil when it has none (it centers and sizes the stack).
    static func position(of node: AppSceneNode) -> AppScenePosition? {
        guard let object = node.props["position"]?.objectValue else { return nil }
        let position = AppScenePosition(x: object["x"]?.numberValue, y: object["y"]?.numberValue,
                                        fraction: object["unit"]?.stringValue == "fraction")
        return position.x == nil && position.y == nil ? nil : position
    }
}

/// A ZStack child's `position`: its center, in points or as a fraction of the stack; a missing axis centers.
struct AppScenePosition: Equatable {
    var x: Double?
    var y: Double?
    var fraction: Bool

    /// The center in `rect` (the stack's content rect, top-left origin: the view is flipped).
    func center(in rect: CGRect) -> CGPoint {
        func place(_ value: Double?, _ origin: CGFloat, _ length: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return origin + length / 2 }
            return origin + (fraction ? CGFloat(value) * length : CGFloat(value))
        }
        return CGPoint(x: place(x, rect.minX, rect.width), y: place(y, rect.minY, rect.height))
    }
}
