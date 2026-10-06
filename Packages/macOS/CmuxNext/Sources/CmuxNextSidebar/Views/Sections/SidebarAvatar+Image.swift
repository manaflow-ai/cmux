import AppKit

extension SidebarAvatar {
    /// A `side` circle: the picture filling it, else the initials in `ink`
    /// on `fill`, rendered at `scale` pixels per point.
    func image(side: CGFloat, scale: CGFloat, fill: CGColor, ink: CGColor) -> NSImage {
        let pixels = Int((side * scale).rounded())
        let image = NSImage(size: NSSize(width: side, height: side))
        guard pixels > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = image.size
        let rect = NSRect(origin: .zero, size: image.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSBezierPath(ovalIn: rect).addClip()
        if let picture = imageData.flatMap(NSImage.init(data:)) {
            // Aspect fill: the shorter side spans the circle.
            let size = picture.size, fit = max(side / max(size.width, 1), side / max(size.height, 1))
            let drawn = NSSize(width: size.width * fit, height: size.height * fit)
            picture.draw(in: NSRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        } else {
            NSColor(cgColor: fill)?.setFill()
            rect.fill()
            let text = NSAttributedString(string: initials, attributes: [
                .font: NSFont.systemFont(ofSize: (side * (initials.count > 1 ? 0.42 : 0.5)).rounded(), weight: .semibold),
                .foregroundColor: NSColor(cgColor: ink) ?? .white,
            ])
            let bounds = text.size()
            text.draw(at: NSPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }
}
