import SwiftUI

/// Draws pack layers with the view's foreground style; clear layers punch
/// out of earlier layers inside one canvas layer.
struct IconCanvas: View {
    let layers: [IconLayer]
    let grid: CGFloat
    let accentColor: Color

    var body: some View {
        Canvas { context, size in
            guard grid > 0 else { return }
            context.scaleBy(x: size.width / grid, y: size.height / grid)
            context.drawLayer { layer in
                for icon in layers {
                    Self.draw(icon, in: layer, accentColor: accentColor)
                }
            }
        }
    }

    private static func draw(_ icon: IconLayer, in layer: GraphicsContext, accentColor: Color) {
        guard let cgPath = CGPath.icon(icon.d) else { return }
        var context = layer
        let path = Path(cgPath)
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
                lineWidth: icon.width,
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
