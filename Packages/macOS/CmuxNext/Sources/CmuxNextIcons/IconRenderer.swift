public import CoreGraphics

/// Draws icon layers into a Core Graphics context.
public nonisolated enum IconRenderer {
    /// The row crop (viewBox 2.5 2.5 19 19): the live area fills the row
    /// height; strokes past it overflow and are not clipped.
    public static let rowCrop = CGRect(x: 2.5, y: 2.5, width: 19, height: 19)

    /// Draws `layers` into `rect` of `context`, whose y axis must point down
    /// (a flipped view or `NSImage(size:flipped: true)`). `crop` is the part
    /// of the grid that maps onto `rect` (the whole grid when nil). Clear
    /// layers erase only what earlier layers drew, inside one transparency layer.
    public static func draw(
        _ layers: [IconLayer],
        in context: CGContext,
        rect: CGRect,
        grid: CGFloat = 24,
        ink: CGColor,
        accent: CGColor? = nil,
        crop: CGRect? = nil
    ) {
        let box = crop ?? CGRect(x: 0, y: 0, width: grid, height: grid)
        guard box.width > 0, box.height > 0, !layers.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for layer in layers {
            draw(layer, in: context, color: layer.accent ? (accent ?? ink) : ink)
        }
        context.endTransparencyLayer()
    }

    private static func draw(_ layer: IconLayer, in context: CGContext, color: CGColor) {
        guard let path = IconPath.cgPath(layer.d) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if layer.op.clears {
            context.setBlendMode(.destinationOut)
        } else {
            context.setAlpha(layer.alpha)
        }
        let paint = layer.op.clears ? CGColor(gray: 0, alpha: 1) : color
        context.addPath(path)
        if layer.op.strokes {
            context.setStrokeColor(paint)
            context.setLineWidth(layer.width)
            context.setLineCap(layer.cap.cgLineCap)
            context.setLineJoin(layer.join.cgLineJoin)
            if !layer.dash.isEmpty {
                context.setLineDash(phase: layer.dashPhase, lengths: layer.dash)
            }
            context.strokePath()
        } else {
            context.setFillColor(paint)
            context.fillPath(using: .winding)
        }
    }
}
