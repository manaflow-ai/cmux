import SwiftUI

/// Draws pack layers with the view's foreground style; clear layers punch
/// out of earlier layers inside one canvas layer. Strokes land on whole
/// pixels of the display (`IconPixelGrid`); SwiftUI places views on whole points.
struct IconCanvas: View {
    let layers: [IconLayer]
    let grid: CGFloat
    let accentColor: Color

    var body: some View {
        Canvas { context, size in
            guard grid > 0 else { return }
            context.scaleBy(x: size.width / grid, y: size.height / grid)
            let pixels = context.environment.displayScale
            let fitted = IconPixelGrid.fit(layers, toDevice: CGAffineTransform(
                scaleX: size.width / grid * pixels, y: size.height / grid * pixels
            ))
            context.drawLayer { layer in
                for icon in fitted {
                    Self.draw(icon, in: layer, accentColor: accentColor)
                }
            }
        }
    }

    private static func draw(_ fitted: FittedIconLayer, in layer: GraphicsContext, accentColor: Color) {
        let icon = fitted.layer
        var context = layer
        let path = Path(fitted.path)
        let shading: GraphicsContext.Shading
        if icon.op.clears {
            context.blendMode = .destinationOut
            shading = .color(.black)
        } else {
            context.opacity = icon.alpha
            shading = icon.accent ? .color(accentColor) : .foreground
        }
        if icon.op.strokes {
            let style = StrokeStyle(
                lineWidth: fitted.width,
                lineCap: icon.cap.cgLineCap,
                lineJoin: icon.join.cgLineJoin,
                dash: icon.dash,
                dashPhase: icon.dashPhase
            )
            context.stroke(path, with: shading, style: style)
        } else {
            context.fill(path, with: shading, style: FillStyle(eoFill: false))
        }
    }
}
