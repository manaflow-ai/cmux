import AppKit
import os

/// SF Symbol masks for chat widget cards, drawn into row bitmaps off the main thread.
// crash-allow: the only state is `masks`, a `let` OSAllocatedUnfairLock; every read and write goes through it.
final class HomeWidgetSymbols: @unchecked Sendable {

    private struct Key: Hashable {
        var name: String
        var points: Int
    }

    // Lock carve-out: rows draw on the bitmap threads synchronously (CustomRows.swift drawRow);
    // a tiny cache read and write per symbol.
    private let masks = OSAllocatedUnfairLock<[Key: CGImage]>(initialState: [:])

    /// Fills the symbol `name` in `rect` (a flipped, top-left origin context) with `color`.
    func draw(_ name: String, in rect: CGRect, color: UIColor, ctx: CGContext) {
        guard let points = Int(exactly: rect.height.rounded()), let mask = mask(name, points: points) else { return }
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
              let width = Int(exactly: size.width.rounded(.up)), let height = Int(exactly: size.height.rounded(.up)),
              let color = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // NSImage draws nothing into an alpha-only context: draw in color, turn the symbol white,
        // then lay it on black in gray, which `clip(to:mask:)` reads as coverage (white paints).
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: color, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        color.setBlendMode(.sourceIn)
        color.setFillColor(CGColor(gray: 1, alpha: 1))
        color.fill(rect)
        guard let white = color.makeImage() else { return nil }
        gray.setFillColor(CGColor(gray: 0, alpha: 1))
        gray.fill(rect)
        gray.draw(white, in: rect)
        guard let mask = gray.makeImage() else { return nil }
        masks.withLock { $0[key] = mask }
        return mask
    }
}
