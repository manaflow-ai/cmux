#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO
import UniformTypeIdentifiers

/// The compose field's attachments, as macOS 27 Messages shows them (lossless
/// stills and a 120 Hz take: references/real-messages/interactions/
/// compose-attach-image/): every attachment is a tile, stacked top to bottom
/// above the text line. An image shows the image itself, aspect-fit in a
/// 177 x 118 pt box (a 600x400 px image: 177 x 118; measured 176.2 x 118), 16 pt continuous
/// corners, 11.8 pt from the field's left, the first tile 7 pt under the field
/// top, 3 pt between tiles; any other file is a tile of the same width with
/// its icon, name and kind and size ("PDF Document · 7 KB"). The field grows
/// by each tile's height + 3 pt, AT ONCE (the take has no in-between frame),
/// and the text line stays the field's bottom 31 pt. A remove button shows on
/// hover (Messages' own control was not captured; ours is an estimate).
/// Fitted on one image aspect (1.5): which side of the box limits other
/// aspects is an estimate; the file tile's height (89 pt) comes from the field
/// growth (92 pt).
///
/// Thumbnails are decoded off the main thread with ImageIO
/// (`CGImageSourceCreateThumbnailAtIndex`, downsampled to the tile's pixel
/// size at the display scale, EXIF orientation applied, the embedded colour
/// profile kept: Core Animation colour-matches a P3 screenshot), so a large
/// screenshot never blocks a frame. Until a thumbnail arrives the tile is the
/// placeholder grey.
final class ComposeAttachmentStrip {
    static let boxWidth: CGFloat = 177           // measured 176.2 from the colour bars (+-1); 177 keeps the 1.5 image 118 tall
    static let imageMaxHeight: CGFloat = 118     // measured (one aspect)
    static let corner: CGFloat = 16              // measured, continuous
    static let left: CGFloat = 11.8              // measured
    static let top: CGFloat = 7                  // measured
    static let gap: CGFloat = 3                  // measured
    static let fileHeight: CGFloat = 89          // from the field growth (92 pt)
    static let removeSize: CGFloat = 18          // estimate

    struct Tile: Equatable { var id: ID; var rect: CGRect; var image: Bool }

    let layer = CALayer()
    private(set) var attachments: [Attachment] = []
    private(set) var tiles: [Tile] = []
    private(set) var height: CGFloat = 0
    private var width: CGFloat = 0
    private var scale: CGFloat = 2
    private var imageLayers: [ID: (image: CALayer, remove: CALayer)] = [:]
    private let pills = CALayer()
    private var thumbs: [String: CGImage] = [:]       // key: asset + pixel size
    private var hovered: ID?
    private static let queue = DispatchQueue(label: "compose.thumbnails", qos: .userInitiated)

    init() {
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        layer.actions = none
        pills.actions = none
        layer.addSublayer(pills)
        pills.zPosition = -1
    }

    static func isImage(_ a: Attachment) -> Bool {
        a.kind == "image" && (a.width ?? 0) > 0 && (a.height ?? 0) > 0 && a.asset != nil
    }

    /// Tiles (field coordinates, top-left of the field) and the strip height
    /// (what the field grows by).
    static func layout(_ atts: [Attachment], width: CGFloat, scale: CGFloat) -> (tiles: [Tile], height: CGFloat) {
        var tiles: [Tile] = []
        var y = top
        for a in atts {
            var size = CGSize(width: boxWidth, height: fileHeight)
            if isImage(a) {
                let w = CGFloat(a.width ?? 1) / scale, h = CGFloat(a.height ?? 1) / scale
                let k = min(1, boxWidth / w, imageMaxHeight / h)    // aspect-fit, never upscaled
                size = CGSize(width: w * k, height: h * k)
            }
            let r = CGRect(x: left, y: y, width: size.width, height: size.height).integralToScale(scale)
            tiles.append(Tile(id: a.id, rect: r, image: isImage(a)))
            y = r.maxY + gap
        }
        return (tiles, y - top)
    }

    static let nameFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
    static let kindFont = UIFont.systemFont(ofSize: 10)
    /// "PDF Document · 7 KB" (the type's localized description and the size).
    static func kindText(_ a: Attachment) -> String {
        let kind = UTType(mimeType: a.mimeType)?.localizedDescription ?? a.mimeType
        guard a.byteSize > 0 else { return kind }
        return "\(kind) \u{00B7} \(ByteCountFormatter.string(fromByteCount: Int64(a.byteSize), countStyle: .file))"
    }

    /// Mirror the draft's attachments for a field of this width.
    func update(_ atts: [Attachment], width w: CGFloat, scale s: CGFloat) {
        guard atts != attachments || w != width || s != scale else { return }
        attachments = atts; width = w; scale = s
        let (t, h) = Self.layout(atts, width: w, scale: s)
        tiles = t; height = h
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let live = Set(t.map(\.id))
        for (id, l) in imageLayers where !live.contains(id) { l.image.removeFromSuperlayer(); imageLayers[id] = nil }
        for tile in t {
            guard let a = atts.first(where: { $0.id == tile.id }) else { continue }
            let pair = imageLayers[tile.id] ?? makeImageLayer()
            imageLayers[tile.id] = pair
            pair.image.frame = tile.rect
            pair.image.contentsScale = s
            pair.remove.frame = CGRect(x: tile.rect.width - Self.removeSize - 4, y: 4, width: Self.removeSize, height: Self.removeSize)
            pair.remove.contentsScale = s
            pair.remove.opacity = hovered == tile.id ? 1 : 0
            if tile.image {
                loadThumbnail(a, into: pair.image, pixels: CGSize(width: tile.rect.width * s, height: tile.rect.height * s))
            } else {
                pair.image.backgroundColor = nil      // the file tile is drawn in the pills bitmap below
            }
        }
        renderPills(t, atts, s)
        CATransaction.commit()
    }

    private func makeImageLayer() -> (image: CALayer, remove: CALayer) {
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull()]
        let l = CALayer()
        l.actions = none
        l.cornerRadius = Self.corner
        l.cornerCurve = .continuous
        l.masksToBounds = true
        l.contentsGravity = .resizeAspectFill
        l.backgroundColor = (Fixture.isLight ? Fixture.chipFill : UIColor(white: 1, alpha: 0.08)).cgColor  // cmux: themed on a light theme
        let x = CALayer()
        x.actions = none
        x.opacity = 0
        x.contents = Self.removeImage(scale: 2)
        l.addSublayer(x)
        layer.addSublayer(l)
        return (l, x)
    }

    private static func removeImage(scale: CGFloat) -> CGImage? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        let s = removeSize
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 0, alpha: 0.55).cgColor)
            c.fillEllipse(in: CGRect(x: 0, y: 0, width: s, height: s))
            c.setStrokeColor(UIColor.white.cgColor)
            c.setLineWidth(1.6)
            c.setLineCap(.round)
            let k: CGFloat = 5.5
            c.move(to: CGPoint(x: k, y: k)); c.addLine(to: CGPoint(x: s - k, y: s - k))
            c.move(to: CGPoint(x: s - k, y: k)); c.addLine(to: CGPoint(x: k, y: s - k))
            c.strokePath()
        }.cgImage
    }

    /// File tiles (one bitmap for all of them): a page icon with the type's
    /// extension, the name (two lines at most) and the kind and size.
    private func renderPills(_ t: [Tile], _ atts: [Attachment], _ s: CGFloat) {
        let files = t.filter { !$0.image }
        guard !files.isEmpty else { pills.contents = nil; pills.frame = .zero; return }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = s
        fmt.opaque = false
        pills.frame = CGRect(x: 0, y: 0, width: width, height: max(1, height + Self.top))
        pills.contentsScale = s
        pills.contents = UIGraphicsImageRenderer(size: pills.frame.size, format: fmt).image { ctx in
            let c = ctx.cgContext
            for tile in files {
                guard let a = atts.first(where: { $0.id == tile.id }) else { continue }
                let r = tile.rect
                (Fixture.isLight ? Fixture.chipFill : UIColor(white: 1, alpha: 0.06)).setFill()  // cmux: themed on a light theme
                UIBezierPath(roundedRect: r, cornerRadius: Self.corner).fill()
                // Page icon: 30 x 40 pt, folded corner, the extension under the lines.
                let ic = CGRect(x: r.minX + 12, y: r.midY - 20, width: 30, height: 40)
                let page = UIBezierPath()
                page.move(to: CGPoint(x: ic.minX, y: ic.minY)); page.addLine(to: CGPoint(x: ic.maxX - 9, y: ic.minY))
                page.addLine(to: CGPoint(x: ic.maxX, y: ic.minY + 9)); page.addLine(to: CGPoint(x: ic.maxX, y: ic.maxY))
                page.addLine(to: CGPoint(x: ic.minX, y: ic.maxY)); page.close()
                UIColor(white: 0.96, alpha: 1).setFill(); page.fill()
                UIColor(white: 0.75, alpha: 1).setFill()
                for k in 0..<3 { c.fill(CGRect(x: ic.minX + 6, y: ic.minY + 12 + CGFloat(k) * 4, width: 16, height: 1.2)) }
                let ext = (a.fileName as NSString).pathExtension.uppercased()
                TextDraw.line(ext, font: .systemFont(ofSize: 6, weight: .semibold), color: UIColor(white: 0.55, alpha: 1),
                              x: ic.midX - TextDraw.width(ext, font: .systemFont(ofSize: 6, weight: .semibold)) / 2, baseline: ic.maxY - 5, in: c)
                let tx = ic.maxX + 10, tw = r.maxX - 10 - tx
                var y = r.midY - 10
                TextDraw.line(Self.fit(a.fileName, Self.nameFont, tw), font: Self.nameFont, color: Fixture.incomingText, x: tx, baseline: y, in: c)
                y += 14
                TextDraw.line(Self.fit(Self.kindText(a), Self.kindFont, tw), font: Self.kindFont, color: Fixture.secondaryText, x: tx, baseline: y, in: c)
            }
        }.cgImage
    }

    /// The text cut with an ellipsis to a width.
    static func fit(_ s: String, _ f: UIFont, _ w: CGFloat) -> String {
        if TextDraw.width(s, font: f) <= w { return s }
        var t = s
        while !t.isEmpty && TextDraw.width(t + "\u{2026}", font: f) > w { t.removeLast() }
        return t + "\u{2026}"
    }

    // MARK: Thumbnails (ImageIO, off main)

    private func loadThumbnail(_ a: Attachment, into l: CALayer, pixels: CGSize) {
        guard let asset = a.asset else { return }
        let maxPx = Int(ceil(max(pixels.width, pixels.height)))
        let key = "\(asset)#\(maxPx)"
        if let img = thumbs[key] { l.contents = img; return }
        let id = a.id
        Self.queue.async { [weak self] in
            let img = Self.thumbnail(asset, maxPixels: maxPx)
            DispatchQueue.main.async {
                guard let self, let img else { return }
                self.thumbs[key] = img
                if self.thumbs.count > 16 { self.thumbs.removeValue(forKey: self.thumbs.keys.first { $0 != key }!) }
                guard let pair = self.imageLayers[id] else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                pair.image.contents = img
                CATransaction.commit()
            }
        }
    }

    /// A downsampled, orientation-corrected thumbnail; never larger than the source.
    static func thumbnail(_ asset: String, maxPixels: Int) -> CGImage? {
        let url = URL(string: asset).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: asset)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: Hit testing and hover (field coordinates)

    /// The attachment whose remove control is at p (a pill anywhere, an image's
    /// remove button), field coordinates.
    func removeHit(_ p: CGPoint) -> ID? {
        for t in tiles {
            let r = CGRect(x: t.rect.maxX - Self.removeSize - 4, y: t.rect.minY + 4, width: Self.removeSize, height: Self.removeSize)
            if r.insetBy(dx: -3, dy: -3).contains(p) { return t.id }
        }
        return nil
    }

    /// Show the remove button of the image under p (nil: none).
    func hover(_ p: CGPoint?) {
        let id = p.flatMap { q in tiles.first { $0.rect.contains(q) }?.id }
        guard id != hovered else { return }
        hovered = id
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (k, l) in imageLayers { l.remove.opacity = k == id ? 1 : 0 }
        CATransaction.commit()
    }

    /// The thumbnail shown for an image (tests).
    func shownImage(_ id: ID) -> CGImage? { imageLayers[id].flatMap { $0.image.contents.map { $0 as! CGImage } } }
}

private extension CGRect {
    /// Whole device pixels (a tile's edges on pixel boundaries).
    func integralToScale(_ s: CGFloat) -> CGRect {
        let x0 = (minX * s).rounded() / s, y0 = (minY * s).rounded() / s
        let x1 = (maxX * s).rounded() / s, y1 = (maxY * s).rounded() / s
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
