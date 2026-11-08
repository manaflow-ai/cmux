import AppKit
import os

/// SF Symbol masks for chat widget cards, drawn into row bitmaps off the main thread.
final class HomeWidgetSymbols: @unchecked Sendable {
    // @unchecked Sendable: the only state is `masks`, behind its lock.

    private struct Key: Hashable {
        var name: String
        var points: Int
    }

    // Lock carve-out: rows draw on the bitmap threads synchronously (CustomRows.swift drawRow);
    // a tiny cache read and write per symbol.
    private let masks = OSAllocatedUnfairLock<[Key: CGImage]>(initialState: [:])

    /// Fills the symbol `name` in `rect` (a flipped, top-left origin context) with `color`.
    func draw(_ name: String, in rect: CGRect, color: UIColor, ctx: CGContext) {
        guard let mask = mask(name, points: Int(rect.height.rounded())) else { return }
        let aspect = CGFloat(mask.width) / CGFloat(max(1, mask.height))
        let width = min(rect.width, rect.height * aspect), height = width / aspect
        let target = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        ctx.saveGState()
        ctx.translateBy(x: target.minX, y: target.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: target.size)
        ctx.clip(to: local, mask: mask)
        ctx.setFillColor(color.cgColor)
        ctx.fill(local)
        ctx.restoreGState()
    }

    private func mask(_ name: String, points: Int) -> CGImage? {
        let key = Key(name: name, points: points)
        if let cached = masks.withLock({ $0[key] }) { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(points), weight: .medium)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        // Twice the point size: sharp at 2x without a per-scale cache.
        let size = CGSize(width: image.size.width * 2, height: image.size.height * 2)
        guard size.width >= 1, size.height >= 1,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let alpha = ctx.makeImage() else { return nil }
        // An alpha-only image is not a mask: rebuild it as one (white where the symbol is).
        guard let provider = alpha.dataProvider,
              let mask = CGImage(maskWidth: alpha.width, height: alpha.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                 bytesPerRow: alpha.bytesPerRow, provider: provider, decode: [1, 0], shouldInterpolate: true)
        else { return nil }
        masks.withLock { $0[key] = mask }
        return mask
    }
}
