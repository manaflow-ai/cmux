import AppKit
import UniformTypeIdentifiers

/// cmux: a file attachment in the transcript, drawn as a card close to macOS 26 Messages'
/// (https://github.com/manaflow-ai/cmux/issues/26395): a neutral card on either side (the incoming
/// bubble's fill and text, never the outgoing accent, so `RowDraw.needsFill` leaves it to the
/// bitmap), the system's icon for the file's type, the name shortened in the middle with its
/// extension kept, and "<the type's localized kind> · <size>" ("Analytics Report · 127 KB").
/// The card is as wide as its text needs, between `minWidth` and `maxWidth`; the icon and the
/// text keep upstream's measured positions (`RowDraw.drawFileRow`). Thread safe: rows draw off
/// the main thread.
enum HomeFileCard {
    static let height: CGFloat = 89.5           // measured (upstream's file row)
    static let maxWidth: CGFloat = 275          // upstream's fixed file row width
    static let minWidth: CGFloat = 180
    /// The text's left edge and right padding (Messages, 2x capture: 84.5 pt and about 22 pt).
    static let textLeft: CGFloat = 84.5
    static let padRight: CGFloat = 22
    static let nameBaseline: CGFloat = 43
    static let detailBaseline: CGFloat = 58.5
    /// The icon's square: a macOS document icon fills about 40 x 52 pt of a 64 pt square, the
    /// size of Messages' document (39 x 52 pt, centred at x 42).
    static let iconSide: CGFloat = 64
    static let iconCenterX: CGFloat = 42
    static var nameFont: UIFont { HomeFonts.system(ofSize: 13, weight: .semibold) } // HomeFonts (cx-qpqs)
    static var detailFont: UIFont { HomeFonts.system(ofSize: 11) } // HomeFonts (cx-qpqs)

    /// Attachments drawn as a card: every kind but media, voice memos and contacts.
    static func isCard(_ a: Attachment) -> Bool {
        !["image", "video", "voiceMemo", "contact"].contains(a.kind)
    }

    static func size(_ a: Attachment, maxWidth columnWidth: CGFloat) -> CGSize {
        let cap = max(minWidth, min(maxWidth, columnWidth))
        let text = max(TextDraw.width(a.fileName, font: nameFont), TextDraw.width(detail(a), font: detailFont))
        let width = min(cap, max(minWidth, (textLeft + text + padRight).rounded(.up)))
        return CGSize(width: width, height: height)
    }

    /// "Analytics Report · 127 KB": the system's localized name for the file's type, else
    /// upstream's generic kinds.
    static func detail(_ a: Attachment) -> String {
        kind(a) + " \u{00B7} " + Format.bytes(a.byteSize)
    }

    static func kind(_ a: Attachment) -> String {
        // A generic base type ("data") says less than upstream's "Document".
        if let t = type(a), !t.isDynamic, ![UTType.data, .item, .content].contains(t), let d = t.localizedDescription, !d.isEmpty { return d }
        return Strings.fileKind(a)
    }

    /// The type of the name's extension (what Finder and Messages show), else of the MIME type.
    static func type(_ a: Attachment) -> UTType? {
        let ext = (a.fileName as NSString).pathExtension
        if !ext.isEmpty, let t = UTType(filenameExtension: ext), !t.isDynamic { return t }
        return UTType(mimeType: a.mimeType)
    }

    /// `name` shortened in the middle until it fits `width`, keeping its extension whole
    /// ("cmux DEV-2026-10…14-02.ips"), as Messages and Finder do. A long or spaced "extension"
    /// (`backup-2026-10-27T15-39-44`, `0 final`) or one that alone does not fit is not kept.
    static func truncated(_ name: String, font: UIFont, width: CGFloat, keepExtension: Bool = true) -> String {
        guard TextDraw.width(name, font: font) > width else { return name }
        let ns = name as NSString
        var ext = keepExtension ? ns.pathExtension : ""
        if ext.count > 8 || ext.contains(" ") || TextDraw.width("\u{2026}." + ext, font: font) > width / 2 { ext = "" }
        let suffix = ext.isEmpty ? "" : "." + ext
        let stem = Array(ext.isEmpty ? name : String(name.dropLast(suffix.count)))
        // Keep the most characters of the stem that fit, split between its start and its end.
        var lo = 0, hi = stem.count
        var best = "\u{2026}" + suffix
        while lo <= hi {
            let keep = (lo + hi) / 2
            let head = (keep + 1) / 2, tail = keep - head
            let candidate = String(stem.prefix(head)) + "\u{2026}" + String(stem.suffix(tail)) + suffix
            if TextDraw.width(candidate, font: font) <= width { best = candidate; lo = keep + 1 } else { hi = keep - 1 }
        }
        return best
    }

    /// The card: neutral fill in `shape`, the type's icon, the name and the detail line, and
    /// upstream's upload progress bar while it uploads.
    static func draw(_ ctx: CGContext, _ a: Attachment, shape: UIBezierPath, body: CGRect) {
        Fixture.incoming.setFill()
        shape.fill()
        let fg = Fixture.incomingText
        let side = iconSide
        let iconRect = CGRect(x: body.minX + iconCenterX - side / 2, y: body.midY - side / 2, width: side, height: side)
        if let icon = icon(a, pixels: CrashGuard.int((side * abs(ctx.ctm.a)).rounded(.up), in: 16...1024)) { // no trap on a NaN scale
            UIImage(cgImage: icon, scale: CGFloat(icon.width) / side).draw(in: iconRect)
        }
        let x = body.minX + textLeft
        let room = body.width - textLeft - padRight
        TextDraw.line(truncated(a.fileName, font: nameFont, width: room), font: nameFont, color: fg, x: x,
                      baseline: body.minY + nameBaseline, in: ctx)
        var sub = detail(a)
        if case let .uploading(pr) = a.transfer {
            sub = Format.bytes(CrashGuard.int(Double(a.byteSize) * pr)) /* no trap on a NaN progress */ + " / " + Format.bytes(a.byteSize)
            let bar = CGRect(x: x, y: body.minY + 64, width: room, height: 4)
            fg.withAlphaComponent(0.3).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: 2).fill()
            fg.setFill()
            UIBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(min(1, max(0, pr))), height: 4), cornerRadius: 2).fill()
        }
        TextDraw.line(truncated(sub, font: detailFont, width: room, keepExtension: false), font: detailFont, color: fg.withAlphaComponent(0.6), x: x,
                      baseline: body.minY + detailBaseline, in: ctx)
    }

    // MARK: Icons

    /// The system icon of the attachment's type at `pixels` square. Not cached here: a row's
    /// bitmap is drawn once per scale and width (RowBitmaps), and IconServices keeps the icon.
    static func icon(_ a: Attachment, pixels: Int) -> CGImage? {
        let px = min(1024, max(16, pixels))
        let image = NSWorkspace.shared.icon(for: type(a) ?? .data)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: LabColorSpace.sRGB,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
