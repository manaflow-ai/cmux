public import CoreGraphics

/// Draws icon layers into a Core Graphics context.
public nonisolated extension CGContext {
    /// Draws `layers` into `rect` of this context, whose y axis must point down
    /// (a flipped view or `NSImage(size:flipped: true)`). `crop` is the part
    /// of the grid that maps onto `rect` (the whole grid when nil). Clear
    /// layers erase only what earlier layers drew, inside one transparency layer.
    /// Strokes and edges land on whole device pixels (`IconPixelGrid`).
    func drawIcon(
        _ layers: [IconLayer],
        in rect: CGRect,
        grid: CGFloat = 24,
        ink: CGColor,
        accent: CGColor? = nil,
        crop: CGRect? = nil
    ) {
        let box = crop ?? CGRect(x: 0, y: 0, width: grid, height: grid)
        guard box.width > 0, box.height > 0, !layers.isEmpty else { return }
        saveGState()
        defer { restoreGState() }
        translateBy(x: rect.minX, y: rect.minY)
        scaleBy(x: rect.width / box.width, y: rect.height / box.height)
        translateBy(x: -box.minX, y: -box.minY)
        let fitted = IconPixelGrid.fit(layers, toDevice: userSpaceToDeviceSpaceTransform)
        beginTransparencyLayer(auxiliaryInfo: nil)
        for layer in fitted {
            drawIconLayer(layer, color: layer.layer.accent ? (accent ?? ink) : ink)
        }
        endTransparencyLayer()
    }

    private func drawIconLayer(_ fitted: FittedIconLayer, color: CGColor) {
        let layer = fitted.layer
        saveGState()
        defer { restoreGState() }
        if layer.op.clears {
            setBlendMode(.destinationOut)
        } else {
            setAlpha(layer.alpha)
        }
        let paint = layer.op.clears ? CGColor(gray: 0, alpha: 1) : color
        addPath(fitted.path)
        if layer.op.strokes {
            setStrokeColor(paint)
            setLineWidth(fitted.width)
            setLineCap(layer.cap.cgLineCap)
            setLineJoin(layer.join.cgLineJoin)
            if !layer.dash.isEmpty {
                setLineDash(phase: layer.dashPhase, lengths: layer.dash)
            }
            strokePath()
        } else {
            setFillColor(paint)
            fillPath(using: .winding)
        }
    }
}
