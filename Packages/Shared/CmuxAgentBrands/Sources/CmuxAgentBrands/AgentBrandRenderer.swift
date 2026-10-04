import CoreGraphics

/// Draws marks with Core Graphics, so AppKit, UIKit and SwiftUI share one renderer.
public enum AgentBrandRenderer {
    /// Builds the path for normalized data (absolute M, L, C and Z). Returns nil on malformed data.
    public static func path(_ d: String) -> CGPath? {
        let path = CGMutablePath()
        var numbers: [Double] = []
        var command: Character?
        var token = ""
        func flushNumber() -> Bool {
            guard !token.isEmpty else { return true }
            guard let value = Double(token) else { return false }
            numbers.append(value)
            token = ""
            return true
        }
        func emit() -> Bool {
            guard let command else { return numbers.isEmpty }
            let arity: Int
            switch command {
            case "M", "L": arity = 2
            case "C": arity = 6
            case "Z": arity = 0
            default: return false
            }
            if arity == 0 {
                guard numbers.isEmpty else { return false }
                path.closeSubpath()
                return true
            }
            guard !numbers.isEmpty, numbers.count.isMultiple(of: arity) else { return false }
            var index = 0
            while index < numbers.count {
                let n = numbers[index..<(index + arity)].map { CGFloat($0) }
                switch command {
                case "M": path.move(to: CGPoint(x: n[0], y: n[1]))
                case "L": path.addLine(to: CGPoint(x: n[0], y: n[1]))
                default: path.addCurve(to: CGPoint(x: n[4], y: n[5]), control1: CGPoint(x: n[0], y: n[1]), control2: CGPoint(x: n[2], y: n[3]))
                }
                index += arity
            }
            return true
        }
        for character in d {
            if character.isLetter && character != "e" && character != "E" {
                guard flushNumber(), emit() else { return nil }
                command = character
                numbers = []
            } else if character == " " || character == "," {
                guard flushNumber() else { return nil }
            } else if character == "-" && !token.isEmpty && token.last != "e" && token.last != "E" {
                guard flushNumber() else { return nil }
                token = "-"
            } else {
                token.append(character)
            }
        }
        guard flushNumber(), emit(), !path.isEmpty else { return nil }
        return path
    }

    /// Draws `spec` fitted and centered in `rect` (y-up or y-down per `flipped`).
    ///
    /// - Parameters:
    ///   - style: `.brand` paints the owner's colors and tile; `.mono` paints every path in `monoColor`.
    ///   - dark: whether the surface behind the mark is dark; picks the brand tone for that side.
    ///   - flipped: true when the context's origin is top-left (UIKit, flipped NSView, SwiftUI);
    ///     false for a bitmap context, whose origin is bottom-left.
    public static func draw(
        _ spec: AgentBrandSpec,
        in context: CGContext,
        rect: CGRect,
        style: AgentBrandStyle,
        dark: Bool,
        monoColor: CGColor,
        flipped: Bool = true
    ) {
        let tile = style == .brand ? spec.tile : nil
        guard let transform = transform(for: spec, in: rect, style: style, flipped: flipped) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(transform)
        if let tile {
            let tileRect = CGRect(x: tile.viewBox.x, y: tile.viewBox.y, width: tile.viewBox.width, height: tile.viewBox.height)
            context.addPath(CGPath(roundedRect: tileRect, cornerWidth: tile.radius, cornerHeight: tile.radius, transform: nil))
            context.setFillColor(color(tile.tone.rgb(dark: dark)))
            context.fillPath()
        }
        for item in spec.paths {
            guard let path = path(item.d) else { continue }
            let alpha: CGFloat
            let fill: CGColor
            switch style {
            case .brand:
                alpha = 1
                fill = color((item.tone ?? spec.tone).rgb(dark: dark))
            case .mono:
                alpha = CGFloat(item.monoOpacity)
                fill = monoColor
            }
            guard alpha > 0 else { continue }
            context.saveGState()
            context.setAlpha(alpha)
            context.addPath(path)
            if let width = item.strokeWidth {
                context.setStrokeColor(fill)
                context.setLineWidth(width)
                context.strokePath()
            } else {
                context.setFillColor(fill)
                context.fillPath(using: item.evenOdd ? .evenOdd : .winding)
            }
            context.restoreGState()
        }
        guard style == .brand else { return }
        for overlay in spec.overlays {
            drawOverlay(overlay, over: spec.paths, in: context)
        }
    }

    /// Maps the mark's view box (the tile's, in the brand style when the mark has one) onto `rect`,
    /// fitted and centered. nil for an empty rect.
    public static func transform(for spec: AgentBrandSpec, in rect: CGRect, style: AgentBrandStyle, flipped: Bool = true) -> CGAffineTransform? {
        let box = (style == .brand ? spec.tile?.viewBox : nil) ?? spec.viewBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        guard scale.isFinite, scale > 0 else { return nil }
        let drawn = CGSize(width: box.width * scale, height: box.height * scale)
        let originX = rect.midX - drawn.width / 2
        let originY = rect.midY - drawn.height / 2
        let place = flipped
            ? CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: originX, ty: originY)
            : CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: originX, ty: originY + drawn.height)
        return CGAffineTransform(translationX: -box.x, y: -box.y).concatenating(place)
    }

    /// Renders a mark into an image of `pixelSize` square pixels, or nil for an empty size.
    public static func image(
        _ spec: AgentBrandSpec,
        pixelSize: Int,
        style: AgentBrandStyle,
        dark: Bool,
        monoColor: CGColor = CGColor(gray: 0, alpha: 1)
    ) -> CGImage? {
        guard pixelSize > 0,
              let context = CGContext(
                  data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        draw(spec, in: context, rect: rect, style: style, dark: dark, monoColor: monoColor, flipped: false)
        return context.makeImage()
    }

    static func color(_ rgb: UInt32, opacity: Double = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: CGFloat(opacity)
        )
    }

    private static func drawOverlay(_ overlay: AgentBrandGradient, over paths: [AgentBrandPathSpec], in context: CGContext) {
        let colors = overlay.stops.map { color($0.color, opacity: $0.opacity) } as CFArray
        let locations = overlay.stops.map { CGFloat($0.offset) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else { return }
        for item in paths where item.strokeWidth == nil {
            guard let path = path(item.d) else { continue }
            context.saveGState()
            context.addPath(path)
            if item.evenOdd { context.clip(using: .evenOdd) } else { context.clip() }
            context.drawLinearGradient(gradient, start: CGPoint(x: overlay.x1, y: overlay.y1), end: CGPoint(x: overlay.x2, y: overlay.y2), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }
    }
}
