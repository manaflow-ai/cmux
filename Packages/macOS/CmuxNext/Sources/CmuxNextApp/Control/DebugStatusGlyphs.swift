import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// The sidebar's status glyphs (`debug.sidebar_rows` "status_glyphs"), in window points with a
/// top-left origin: each visible shared indicator, the box its mark actually draws (from the
/// mark's mask), how soft that mask is at 1x and 2x, its row title's cap-height center and the
/// row's unread badge. scripts/cmux-next/sidebar-status-glyph-live.py checks them (Leo
/// 2026-10-13: the done and working marks read tiny, blurry and low next to the badge).
@MainActor
enum DebugStatusGlyphs {
    static func report(in sidebar: NSView) -> [JSONValue] {
        guard let window = sidebar.window else { return [] }
        let height = window.contentView?.bounds.height ?? window.frame.height
        func topLeft(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: nil)
            return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        var glyphs: [JSONValue] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if let indicator = view as? StatusIndicatorView {
                // A pooled row's indicator is laid out at zero size until the row shows.
                if indicator.showsGlyph, indicator.bounds.width > 0 { glyphs.append(describe(indicator, frame: topLeft(indicator), topLeft: topLeft)) }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(sidebar)
        return glyphs
    }

    private static func describe(_ indicator: StatusIndicatorView, frame: CGRect, topLeft: (NSView) -> CGRect) -> JSONValue {
        let scale = indicator.window?.backingScaleFactor ?? 2
        let glyph = indicator.indicator.debugGlyphRect
        var fields: [String: JSONValue] = [
            "state": .string(String(describing: indicator.state)),
            "frame": rect(frame),
            "scale": .number(Double(scale)),
            // The unread badge's height (`SidebarStyle.badgeHeight`), shown or not.
            "badge_height": .number(Double(Metrics.iconSize)),
        ]
        if let mask = indicator.indicator.debugMarkMask(scale: scale), let box = alphaBox(mask) {
            // Mask rows run top to bottom; the glyph square is centered in the indicator.
            let side = CGFloat(mask.width) / scale
            let origin = CGPoint(x: frame.midX - side / 2, y: frame.midY - side / 2)
            fields["drawn"] = rect(CGRect(x: origin.x + box.minX / scale, y: origin.y + box.minY / scale,
                                          width: box.width / scale, height: box.height / scale))
            fields["glyph_side"] = .number(Double(glyph.width))
        }
        for (key, pixelsPerPoint) in [("soft_1x", 1.0), ("soft_2x", 2.0)] {
            fields[key] = indicator.indicator.debugMarkMask(scale: pixelsPerPoint).flatMap(softness).map { .number($0) } ?? .null
        }
        if let row = sequence(first: indicator.superview, next: { $0?.superview }).lazy.compactMap({ $0 })
            .first(where: { String(describing: type(of: $0)).hasSuffix("RowView") }) {
            // The row's own text, not a badge's count.
            func inBadge(_ field: NSView) -> Bool {
                sequence(first: field.superview, next: { $0?.superview }).lazy.compactMap { $0 }
                    .prefix { $0 !== row }.contains { String(describing: type(of: $0)).contains("Badge") }
            }
            let labels = textFields(in: row).filter { !$0.isHidden && !$0.stringValue.isEmpty && !inBadge($0) }
            // A workspace row's title is a MarqueeLabel, top-aligned: its baseline sits the font's
            // ascender below its top.
            if let title = views(in: row).lazy.compactMap({ $0 as? MarqueeLabel }).first(where: { !$0.isHidden && !$0.stringValue.isEmpty }) {
                let box = topLeft(title)
                fields["title"] = .object([
                    "text": .string(title.stringValue),
                    "cap_center_y": .number(Double(box.minY + title.font.ascender - title.font.capHeight / 2)),
                ])
            } else if let title = labels.max(by: { ($0.font?.pointSize ?? 0) < ($1.font?.pointSize ?? 0) }), let font = title.font {
                let box = topLeft(title)
                fields["title"] = .object([
                    "text": .string(title.stringValue),
                    "cap_center_y": .number(Double(box.minY + title.firstBaselineOffsetFromTop - font.capHeight / 2)),
                ])
            }
            if let badge = views(in: row).first(where: { String(describing: type(of: $0)) == "UnreadBadgeView" && !$0.isHidden }) {
                fields["badge"] = rect(topLeft(badge))
            }
        }
        return .object(fields)
    }

    /// Partly covered pixels per fully covered one: a mark drawn at its pixel size has only its
    /// outline partly covered; one resampled from another size is soft all through.
    private static func softness(_ mask: CGImage) -> Double? {
        guard let alpha = alphaBytes(mask) else { return nil }
        let partial = alpha.filter { $0 > 12 && $0 < 243 }.count
        let solid = alpha.filter { $0 >= 243 }.count
        return (Double(partial) / Double(max(1, solid)) * 100).rounded() / 100
    }

    /// The box of pixels at least half covered, in mask pixels (rows top to bottom).
    private static func alphaBox(_ mask: CGImage) -> CGRect? {
        guard let alpha = alphaBytes(mask) else { return nil }
        let width = mask.width
        var minX = width, minY = mask.height, maxX = -1, maxY = -1
        for (index, value) in alpha.enumerated() where value > 127 {
            let x = index % width, y = index / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func alphaBytes(_ mask: CGImage) -> [UInt8]? {
        let width = mask.width, height = mask.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func views(in view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(views) }
    private static func textFields(in view: NSView) -> [NSTextField] { views(in: view).compactMap { $0 as? NSTextField } }

    private static func rect(_ r: CGRect) -> JSONValue {
        .array([r.minX, r.minY, r.width, r.height].map { .number((Double($0) * 100).rounded() / 100) })
    }
}
