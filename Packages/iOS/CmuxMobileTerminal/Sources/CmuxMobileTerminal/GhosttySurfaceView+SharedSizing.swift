#if canImport(UIKit)
import CmuxMobileTerminalKit
import QuartzCore
import UIKit

/// The decorative layers of the shared-sizing bounds: owner-color border,
/// hatch outside the grid, and amber fades on cut edges. None of them take
/// touches or key events.
final class GhosttySurfaceSharedSizingLayers {
    /// Amber used for the cut-edge fade.
    static let cutFadeColor = UIColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1)
    /// Distance between hatch lines, in points.
    static let hatchSpacing: CGFloat = 7

    let container = CALayer()
    let border = CAShapeLayer()
    let hatch = CAShapeLayer()
    let hatchMask = CAShapeLayer()
    var fades: [CAGradientLayer] = []

    init(host: CALayer) {
        let noActions: [String: any CAAction] = [
            "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(),
            "opacity": NSNull(), "path": NSNull(), "position": NSNull(),
            "strokeColor": NSNull(), "sublayers": NSNull(), "colors": NSNull(),
        ]
        container.name = "cmux.sharedSizing"
        container.zPosition = 1000 // above the Ghostty renderer layer
        container.actions = noActions
        hatch.fillColor = UIColor.clear.cgColor
        hatch.lineWidth = 1
        hatch.actions = noActions
        hatchMask.actions = noActions
        hatch.mask = hatchMask
        border.fillColor = UIColor.clear.cgColor
        border.lineWidth = TerminalSizingBoundsGeometry.borderWidth
        border.actions = noActions
        container.addSublayer(hatch)
        container.addSublayer(border)
        host.addSublayer(container)
    }

    func hide() {
        container.isHidden = true
    }

    func apply(
        geometry: TerminalSizingBoundsGeometry,
        ownerColor: UIColor,
        hatchColor: UIColor,
        bounds: CGRect,
        scale: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let borderRect = geometry.borderRect else {
            container.isHidden = true
            return
        }
        container.isHidden = false
        container.frame = bounds
        container.contentsScale = scale
        for layer in [border, hatch, hatchMask] as [CALayer] {
            layer.frame = bounds
            layer.contentsScale = scale
        }

        let inset = TerminalSizingBoundsGeometry.borderWidth / 2
        border.strokeColor = ownerColor.cgColor
        border.path = UIBezierPath(rect: borderRect.insetBy(dx: inset, dy: inset)).cgPath

        let maskPath = UIBezierPath()
        for rect in geometry.hatchRects {
            maskPath.append(UIBezierPath(rect: rect))
        }
        hatchMask.path = maskPath.cgPath
        hatch.strokeColor = hatchColor.cgColor
        hatch.path = geometry.hatchRects.isEmpty ? nil : Self.hatchPath(in: bounds)

        fades.forEach { $0.removeFromSuperlayer() }
        fades = geometry.cutFades.map { fade in
            let layer = CAGradientLayer()
            layer.actions = ["bounds": NSNull(), "frame": NSNull(), "position": NSNull()]
            layer.frame = fade.rect
            layer.contentsScale = scale
            layer.colors = [
                Self.cutFadeColor.withAlphaComponent(0).cgColor,
                Self.cutFadeColor.withAlphaComponent(0.45).cgColor,
            ]
            switch fade.edge {
            case .trailing:
                layer.startPoint = CGPoint(x: 0, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 0.5)
            case .top:
                layer.startPoint = CGPoint(x: 0.5, y: 1)
                layer.endPoint = CGPoint(x: 0.5, y: 0)
            }
            container.addSublayer(layer)
            return layer
        }
    }

    /// Diagonal lines across `rect`, clipped later by the hatch mask.
    static func hatchPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        var offset = -rect.height
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += hatchSpacing
        }
        return path
    }
}

extension GhosttySurfaceView {
    /// Redraws the shared-sizing layers from the current decoration and the
    /// last letterbox geometry. Hides them when there is no decoration.
    func refreshSharedSizingLayers() {
        guard let decoration = sharedSizingDecoration,
              let viewportRect = lastLetterboxViewportRect,
              !lastRenderRect.isEmpty else {
            sharedSizingLayers?.hide()
            return
        }
        let layers: GhosttySurfaceSharedSizingLayers
        if let existing = sharedSizingLayers {
            layers = existing
        } else {
            layers = GhosttySurfaceSharedSizingLayers(host: layer)
            sharedSizingLayers = layers
        }
        let ownerColor = UIColor(
            red: decoration.ownerRed,
            green: decoration.ownerGreen,
            blue: decoration.ownerBlue,
            alpha: 1
        )
        layers.apply(
            geometry: decoration.geometry(viewportRect: viewportRect, renderRect: lastRenderRect),
            ownerColor: ownerColor,
            hatchColor: UIColor.separator.resolvedColor(with: traitCollection),
            bounds: layer.bounds,
            scale: max(layer.contentsScale, 1)
        )
    }
}
#endif
