import AppKit
import CmuxNextDesign

/// `edgeGlow`: a soft gradient growing inward from the edge the new pane
/// takes (every edge for a center drop), clipped to the target's shape.
final class EdgeGlowRenderer: DropOverlayRenderer {
    let style = DropOverlayStyle.edgeGlow
    let view = DropOverlayRenderers.container()
    private let clip = CALayer()
    private let clipMask = DropOverlayRenderers.shape()
    private var glows: [CGRectEdge: CAGradientLayer] = [:]
    private let label = DropOverlayLabel()

    init() {
        clip.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        clipMask.fillColor = NSColor.black.cgColor
        clip.mask = clipMask
        for edge in [CGRectEdge.minXEdge, .maxXEdge, .minYEdge, .maxYEdge] {
            let gradient = CAGradientLayer()
            gradient.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "colors": NSNull(), "opacity": NSNull()]
            // Gradient start at the edge, end inward (layer space is flipped like the plane).
            switch edge {
            case .minXEdge: (gradient.startPoint, gradient.endPoint) = (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
            case .maxXEdge: (gradient.startPoint, gradient.endPoint) = (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
            case .minYEdge: (gradient.startPoint, gradient.endPoint) = (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
            case .maxYEdge: (gradient.startPoint, gradient.endPoint) = (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
            }
            clip.addSublayer(gradient)
            glows[edge] = gradient
        }
        view.layer?.addSublayer(clip)
        view.addSubview(label.field)
    }

    func update(_ frame: DropOverlayFrame) {
        let edges = Set(DropOverlayGeometry.glowEdges(frame.zone))
        let depth = CGFloat(DropOverlayTunables.glowWidth.value)
        let local = CGRect(origin: .zero, size: frame.target.size)
        Motion.transaction(nil) {
            clip.frame = frame.target
            clipMask.frame = local
            clipMask.path = DropOverlayGeometry.roundedRect(local, frame.cornerRadius)
            for (edge, gradient) in glows {
                gradient.isHidden = !edges.contains(edge)
                gradient.frame = DropOverlayGeometry.band(local, edge: edge, depth: depth)
                gradient.opacity = Float(DropOverlayTunables.glowOpacity.value)
            }
        }
        label.place(in: frame.target, frame: frame)
    }

    func applyTheme() {
        view.performWithTheme {
            let color = Palette.tunable(DropOverlayTunables.color.value).withAlphaComponent(1)
            let colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
            for gradient in glows.values { gradient.colors = colors }
            label.applyTheme(Palette.textPrimary)
        }
    }
}

/// `dimOthers`: a spotlight. Everything in the layout outside the target is
/// dimmed with the theme's shadow color; a hairline traces the lit target.
final class DimOthersRenderer: DropOverlayRenderer {
    let style = DropOverlayStyle.dimOthers
    let view = DropOverlayRenderers.container()
    private let scrim = DropOverlayRenderers.shape()
    private let outline = DropOverlayRenderers.shape()
    private let label = DropOverlayLabel()

    init() {
        scrim.fillRule = .evenOdd
        outline.fillColor = nil
        view.layer?.addSublayer(scrim)
        view.layer?.addSublayer(outline)
        view.addSubview(label.field)
    }

    func update(_ frame: DropOverlayFrame) {
        let pixel = 1 / max(view.window?.backingScaleFactor ?? 2, 1)
        Motion.transaction(nil) {
            scrim.path = DropOverlayGeometry.spotlightPath(bounds: frame.bounds, hole: frame.target, cornerRadius: frame.cornerRadius)
            scrim.opacity = Float(DropOverlayTunables.dimAmount.value)
            outline.isHidden = !DropOverlayTunables.dimOutline.value
            outline.lineWidth = pixel
            outline.path = DropOverlayGeometry.roundedRect(frame.target.insetBy(dx: pixel / 2, dy: pixel / 2), frame.cornerRadius)
        }
        label.place(in: frame.target, frame: frame)
    }

    func applyTheme() {
        view.performWithTheme {
            scrim.fillColor = Palette.shadow.withAlphaComponent(1).cgColor
            outline.strokeColor = Palette.tunable(DropOverlayTunables.color.value).withAlphaComponent(0.6).cgColor
            label.applyTheme(Palette.textPrimary)
        }
    }
}
