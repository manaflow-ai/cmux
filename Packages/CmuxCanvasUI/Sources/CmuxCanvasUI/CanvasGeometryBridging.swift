import Foundation
import CmuxCanvas

extension CanvasRect {
    /// Bridges a model rect to AppKit geometry (same y-down space as a flipped view).
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Bridges AppKit geometry (flipped/y-down) into the canvas model space.
    init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }
}

extension CGRect {
    /// The rect's center point, used for magnification anchoring.
    var canvasCenter: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

extension CanvasPoint {
    /// Bridges a model point to AppKit geometry.
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    /// Bridges an AppKit point (flipped/y-down space) into the canvas model space.
    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }
}

extension CanvasSize {
    /// Bridges a model size to AppKit geometry.
    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    /// Bridges an AppKit size into the canvas model space.
    init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }
}
