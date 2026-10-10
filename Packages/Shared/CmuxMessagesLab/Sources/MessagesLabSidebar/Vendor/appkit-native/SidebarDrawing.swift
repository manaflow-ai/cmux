import os // OSAllocatedUnfairLock for the monogram font cache
import AppKit
import CoreText

/// What a row or tile bitmap depends on. Everything here is a value read on the main thread,
/// so a background queue can render from it.
struct SidebarRenderContext {
    var metrics: SidebarMetrics
    var palette: SidebarPalette
    var scale: CGFloat
    var space: CGColorSpace
    /// Bumped by any palette, scale or color-space change: older bitmaps are stale.
    var generation: Int
    /// Muted glyph (bell.slash.fill), tinted secondary and selected (rendered on main).
    var bellSecondary: CGImage?
    var bellSelected: CGImage?
    /// Not-delivered glyph (exclamationmark.circle.fill), red and selected (rendered on main).
    var failed: CGImage? = nil
    var failedSelected: CGImage? = nil
    var now: Date
}

/// One bitmap's identity.
struct SidebarBitmapKey: Hashable {
    /// `tile`: a pinned tile's name; `tileBubble`: its newest-message bubble.
    enum Kind: Hashable { case row, time, tile, tileBubble }
    var kind: Kind
    var id: ConversationID
    var version: Int
    var width: CGFloat
    /// Drawn on the emphasized selection (white text).
    var emphasized: Bool
    var generation: Int
}

/// Bitmaps of one sidebar, least recently used out first, with a byte budget. Main thread
/// only (the render queue hands its results to the main thread).
final class SidebarBitmapCache {
    private var map: [SidebarBitmapKey: (image: CGImage, bytes: Int, used: UInt64)] = [:]
    private var clock: UInt64 = 0
    private(set) var bytes = 0
    let budget: Int
    init(budget: Int = 40 << 20) { self.budget = budget }

    func image(_ k: SidebarBitmapKey) -> CGImage? {
        guard var e = map[k] else { return nil }
        clock += 1
        e.used = clock
        map[k] = e
        return e.image
    }
    func contains(_ k: SidebarBitmapKey) -> Bool { map[k] != nil }
    var keys: Set<SidebarBitmapKey> { Set(map.keys) }
    func insert(_ k: SidebarBitmapKey, _ img: CGImage) {
        clock += 1
        let b = img.bytesPerRow * img.height
        if let old = map[k] { bytes -= old.bytes }
        map[k] = (img, b, clock)
        bytes += b
        guard bytes > budget else { return }
        // Evict the oldest third in one pass (amortized O(1) per insert).
        let sorted = map.sorted { $0.value.used < $1.value.used }
        var dropped: [CGImage] = []
        for (key, v) in sorted where bytes > budget * 2 / 3 {
            map[key] = nil
            bytes -= v.bytes
            dropped.append(v.image)
        }
        SidebarDraw.release(dropped)
    }
    func removeAll() { SidebarDraw.release(Array(map.values.map(\.image))); map.removeAll(); bytes = 0 }
    var count: Int { map.count }
}

/// Circle avatars by spec, diameter, scale and appearance; shared by the rows, tiles and the
/// header. Locked (the render queue reads it).
final class SidebarAvatarCache {
    private struct Key: Hashable { var spec: AvatarSpec; var d: CGFloat; var scale: CGFloat; var dark: Bool }
    private var map: [Key: CGImage] = [:]
    private let lock = NSLock()

    func image(_ spec: AvatarSpec, diameter d: CGFloat, ctx: SidebarRenderContext) -> CGImage? { // nil when the bitmap cannot be allocated
        let k = Key(spec: spec, d: d, scale: ctx.scale, dark: ctx.palette.dark)
        lock.lock()
        if let img = map[k] { lock.unlock(); return img }
        lock.unlock()
        guard let img = SidebarDraw.bitmap(size: CGSize(width: d, height: d), ctx: ctx, { g in
            SidebarDraw.avatar(spec, in: CGRect(x: 0, y: 0, width: d, height: d), g, ctx.palette)
        }) else { return nil }
        lock.lock()
        if map.count > 4000 { map.removeAll() }
        map[k] = img
        lock.unlock()
        return img
    }
    func removeAll() { lock.lock(); map.removeAll(); lock.unlock() }
}

/// The drawing: pure functions of a summary and a render context (any thread).
enum SidebarDraw {
    static let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB() // no force unwrap
    /// Where `AvatarSpec.image` paths resolve (the host sets it; default: the app bundle's
    /// "assets" folder).
    static var assetDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("assets")
    /// Frees bitmaps off the main thread (a large free can block it), after Core Animation
    /// has dropped its references in the current turn.
    static func release(_ images: [CGImage]) {
        guard !images.isEmpty else { return }
        DispatchQueue.main.async { DispatchQueue.global(qos: .utility).async { withExtendedLifetime(images) {} } }
    }
    // no force unwrap: Core Text's UI font lookup returns an optional.
    static let nameFont = uiFont(.emphasizedSystem, SidebarMetrics.nameSize)
    static let previewFont = uiFont(.system, SidebarMetrics.previewSize)
    static let timeFont = uiFont(.system, SidebarMetrics.timeSize)
    static let pinNameFont = uiFont(.system, SidebarMetrics.pinNameSize)
    static let bubbleFont = uiFont(.system, 11)

    // the UI font, or Helvetica at that size when Core Text returns none.
    static func uiFont(_ type: CTFontUIFontType, _ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(type, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    // monogram fonts held per half point for the process: avatars draw on
    // concurrentPerform threads, and a font made and dropped per draw can come
    // back nil there (cx-qpqs).
    private static let monogramFonts = OSAllocatedUnfairLock<[CGFloat: CTFont]>(initialState: [:])
    static func monogramFont(_ size: CGFloat) -> CTFont {
        let key = (size * 2).rounded() / 2
        return monogramFonts.withLock { fonts in
            if let held = fonts[key] { return held }
            let font = uiFont(.emphasizedSystem, key)
            fonts.updateValue(font, forKey: key) // dictionary write
            return font
        }
    }

    /// A flipped (top-left origin) bitmap in the context's color space at its scale.
    static func bitmap(size: CGSize, ctx: SidebarRenderContext, _ draw: (CGContext) -> Void) -> CGImage? { // nil when the bitmap cannot be allocated
        let w = max(1, CrashGuard.int((size.width * ctx.scale).rounded(.up))), h = max(1, CrashGuard.int((size.height * ctx.scale).rounded(.up))) // no trap on NaN
        // no force unwraps; an allocation that fails draws nothing (logged once).
        guard let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: ctx.space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return SidebarBitmapFailure.checked(nil, size: size)
        }
        g.translateBy(x: 0, y: CGFloat(h))
        g.scaleBy(x: ctx.scale, y: -ctx.scale)
        g.setShouldSmoothFonts(false)
        draw(g)
        return SidebarBitmapFailure.checked(g.makeImage(), size: size)
    }

    static func line(_ s: String, _ font: CTFont, _ color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
    }
    static func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }
    static func truncated(_ l: CTLine, _ w: CGFloat, _ font: CTFont, _ color: CGColor) -> CTLine {
        guard width(l) > w else { return l }
        return CTLineCreateTruncatedLine(l, Double(max(1, w)), .end, line("…", font, color)) ?? l
    }
    static func draw(_ l: CTLine, x: CGFloat, baseline: CGFloat, _ g: CGContext) {
        g.saveGState()
        g.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        g.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(l, g)
        g.restoreGState()
    }
    /// Up to `lines` lines of `s` in `w`, the last one truncated.
    static func wrapped(_ s: String, _ font: CTFont, _ color: CGColor, width w: CGFloat, lines: Int) -> [CTLine] {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        let attr = NSAttributedString(string: flat, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        let ts = CTTypesetterCreateWithAttributedString(attr)
        let n = attr.length
        var out: [CTLine] = []
        var start = 0
        while start < n, out.count < lines {
            if out.count == lines - 1 {
                let rest = CTTypesetterCreateLine(ts, CFRange(location: start, length: n - start))
                out.append(truncated(rest, w, font, color))
                break
            }
            let count = CTTypesetterSuggestLineBreak(ts, start, Double(w))
            if count <= 0 { break }
            out.append(CTTypesetterCreateLine(ts, CFRange(location: start, length: count)))
            start += count
        }
        return out
    }

    // MARK: Avatars

    static func avatar(_ spec: AvatarSpec, in r: CGRect, _ g: CGContext, _ p: SidebarPalette) {
        switch spec {
        case let .monogram(m):
            g.saveGState()
            g.addEllipse(in: r); g.clip()
            // an optional gradient draws nothing when it fails (SidebarCrashSafe).
            let grad = CGGradient(colorsSpace: nil, colors: [p.monogramTop, p.monogramBottom] as CFArray, locations: [0, 1])
            g.drawLinearGradient(grad, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
            g.restoreGState()
            let font = monogramFont((r.width * 0.42).rounded()) // held, no force unwrap (cx-qpqs)
            let white = CGColor(gray: 1, alpha: 1)
            let l = line(m.uppercased(), font, white)
            let lw = width(l)
            let asc = CTFontGetAscent(font), cap = CTFontGetCapHeight(font)
            _ = asc
            draw(l, x: r.midX - lw / 2, baseline: r.midY + cap / 2, g)
        case let .image(path):
            g.saveGState()
            g.addEllipse(in: r); g.clip()
            let url = path.hasPrefix("file:") ? URL(string: path) : assetDirectory?.appendingPathComponent(path)
            if let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                g.translateBy(x: r.minX, y: r.maxY); g.scaleBy(x: 1, y: -1)
                g.draw(img, in: CGRect(origin: .zero, size: r.size))
            } else {
                g.setFillColor(p.monogramBottom); g.fill(r)
            }
            g.restoreGState()
        case let .emoji(e):
            g.setFillColor(p.groupDisc)
            g.fillEllipse(in: r)
            let font = CTFontCreateWithName("AppleColorEmoji" as CFString, r.width * 0.5, nil)
            let l = line(e, font, CGColor(gray: 0, alpha: 1))
            var asc: CGFloat = 0, desc: CGFloat = 0
            let lw = CGFloat(CTLineGetTypographicBounds(l, &asc, &desc, nil))
            draw(l, x: r.midX - lw / 2, baseline: r.midY + (asc - desc) / 2, g)
        case let .group(members):
            g.setFillColor(p.groupDisc)
            g.fillEllipse(in: r)
            let d = r.width
            let m = Array(members.prefix(4))
            let slots: [(CGFloat, CGFloat, CGFloat)]
            switch m.count {
            case 0, 1: slots = [(0.18, 0.18, 0.64)]
            case 2: slots = [(0.10, 0.10, 0.52), (0.38, 0.38, 0.52)]
            case 3: slots = [(0.27, 0.07, 0.46), (0.07, 0.45, 0.46), (0.47, 0.45, 0.46)]
            default: slots = [(0.08, 0.08, 0.42), (0.50, 0.08, 0.42), (0.08, 0.50, 0.42), (0.50, 0.50, 0.42)]
            }
            for (s, member) in zip(slots, m.map(Optional.some) + Array(repeating: nil, count: max(0, slots.count - m.count))) { // no index math
                let sub = CGRect(x: r.minX + s.0 * d, y: r.minY + s.1 * d, width: s.2 * d, height: s.2 * d)
                // A ring in the disc's color separates overlapping members.
                g.setFillColor(p.groupDisc)
                g.fillEllipse(in: sub.insetBy(dx: -max(1, d * 0.02), dy: -max(1, d * 0.02)))
                avatar(member ?? .monogram(""), in: sub, g, p)
            }
        }
    }

    // MARK: Row

    /// The row's parts, each its own layer: the avatar (shared avatar bitmap) and the unread
    /// dot do not depend on the width; the time (with the muted glyph) is right-aligned and
    /// does not depend on it either; only the text (name and 2-line preview) is redrawn when
    /// the width changes, from cached measurement (SidebarTextCache), so a live resize redraws
    /// the visible rows' text at the exact width in every frame.
    static func rowTime(_ c: ConversationSummary, emphasized: Bool, ctx: SidebarRenderContext, time: ConversationTimeFormatter) -> CGImage? { // nil when the bitmap cannot be allocated
        let p = ctx.palette
        let secondary = emphasized ? p.selectedText.copy(alpha: 0.82) ?? p.selectedText : p.secondary // no force unwrap
        // `.distantPast`: a row without a time (the host's extra search results).
        let tl = line(c.lastAt == .distantPast ? "" : time.string(c.lastAt, now: ctx.now), timeFont, secondary)
        // Glyphs before the time, right to left: the muted bell, then the not-delivered mark.
        let glyphs = [c.failed ? (emphasized ? ctx.failedSelected : ctx.failed) : nil,
                      c.muted ? (emphasized ? ctx.bellSelected : ctx.bellSecondary) : nil].compactMap { $0 }
        let gw = glyphs.reduce(CGFloat(0)) { $0 + CGFloat($1.width) / ctx.scale + 4 }
        let size = CGSize(width: (width(tl) + gw).rounded(.up), height: SidebarMetrics.rowHeight)
        return bitmap(size: size, ctx: ctx) { g in
            draw(tl, x: size.width - width(tl), baseline: SidebarMetrics.nameBaseline, g)
            var x: CGFloat = 0
            for img in glyphs {
                let w = CGFloat(img.width) / ctx.scale, h = CGFloat(img.height) / ctx.scale
                let br = CGRect(x: x, y: SidebarMetrics.nameBaseline - 4.5 - h / 2, width: w, height: h)
                g.saveGState(); g.translateBy(x: br.minX, y: br.maxY); g.scaleBy(x: 1, y: -1)
                g.draw(img, in: CGRect(origin: .zero, size: br.size)); g.restoreGState()
                x += w + 4
            }
        }
    }
    /// The time part's width (the name stops before it).
    static func rowTimeWidth(_ img: CGImage, scale: CGFloat) -> CGFloat { CGFloat(img.width) / scale }

    /// Name and preview at the list's text width; `timeWidth`: the time part's width.
    static func rowText(_ c: ConversationSummary, emphasized: Bool, ctx: SidebarRenderContext, timeWidth: CGFloat,
                        text: SidebarTextCache) -> CGImage? { // nil when the bitmap cannot be allocated
        let t = rowTextLines(c, emphasized: emphasized, ctx: ctx, timeWidth: timeWidth, text: text)
        return drawRowText(name: t.name, preview: t.preview, ctx: ctx)
    }

    /// Everything a row's text bitmap depends on other than its key: where the name is truncated
    /// (nil: the whole name fits), where the preview's lines break, and where its last line is
    /// truncated (nil: not truncated). The lines are drawn left-aligned at x 0, so two text widths
    /// with the same layout draw the same pixels (the wider bitmap's extra columns are empty; the
    /// layer's contents gravity is top-left, nothing is scaled).
    struct RowTextLayout: Equatable {
        var name: CGFloat?
        var breaks: [Int]
        var lastLine: Bool
        var truncatedAt: CGFloat?
        var scale: CGFloat
    }

    /// The text bitmap and its layout; nil image when the layout equals `shown` (the bitmap on
    /// screen, drawn at another width, has these pixels already); nil when the bitmap cannot be allocated.
    static func rowText(_ c: ConversationSummary, emphasized: Bool, ctx: SidebarRenderContext, timeWidth: CGFloat,
                        text: SidebarTextCache, unless shown: RowTextLayout?) -> (image: CGImage?, layout: RowTextLayout)? {
        let t = rowTextLines(c, emphasized: emphasized, ctx: ctx, timeWidth: timeWidth, text: text)
        if let shown, shown == t.layout { return (nil, t.layout) }
        guard let image = drawRowText(name: t.name, preview: t.preview, ctx: ctx) else { return nil }
        return (image, t.layout)
    }

    /// A row's name line, preview lines and their layout at the list's text width.
    private static func rowTextLines(_ c: ConversationSummary, emphasized: Bool, ctx: SidebarRenderContext, timeWidth: CGFloat,
                                     text: SidebarTextCache) -> (name: CTLine, preview: [CTLine], layout: RowTextLayout) {
        let M = SidebarMetrics.self
        let w = ctx.metrics.textWidth
        let m = text.measure(c, emphasized: emphasized, palette: ctx.palette, generation: ctx.generation)
        let nameW = w - timeWidth - M.timeGap
        let name = truncated(m.name, nameW, nameFont, m.nameColor)
        var layout = RowTextLayout(name: name === m.name ? nil : nameW, breaks: [], lastLine: false, truncatedAt: nil, scale: ctx.scale)
        var preview: [CTLine] = []
        if !c.typing, let ts = m.preview {
            let r = linesWithBreaks(ts, length: m.previewLength, font: previewFont, color: m.secondary, width: w, lines: 2)
            preview = r.lines
            layout.breaks = r.breaks; layout.lastLine = r.lastLine; layout.truncatedAt = r.truncatedAt
        }
        return (name, preview, layout)
    }

    private static func drawRowText(name: CTLine, preview: [CTLine], ctx: SidebarRenderContext) -> CGImage? { // nil when the bitmap cannot be allocated
        let M = SidebarMetrics.self
        return bitmap(size: CGSize(width: max(1, ctx.metrics.textWidth), height: M.rowHeight), ctx: ctx) { g in
            draw(name, x: 0, baseline: M.nameBaseline, g)
            for (i, l) in preview.enumerated() {
                draw(l, x: 0, baseline: M.previewBaseline + CGFloat(i) * M.previewLineHeight, g)
            }
        }
    }

    /// Line breaking from a cached typesetter (the measurement), the last line truncated.
    static func lines(_ ts: CTTypesetter, length n: Int, font: CTFont, color: CGColor, width w: CGFloat, lines: Int) -> [CTLine] {
        linesWithBreaks(ts, length: n, font: font, color: color, width: w, lines: lines).lines
    }
    /// `lines` and what decides them: the length of each line broken by the typesetter, whether a
    /// last line (the rest, truncated to the width when longer) follows, and the width it was
    /// truncated at (nil: it fits).
    static func linesWithBreaks(_ ts: CTTypesetter, length n: Int, font: CTFont, color: CGColor, width w: CGFloat,
                                lines: Int) -> (lines: [CTLine], breaks: [Int], lastLine: Bool, truncatedAt: CGFloat?) {
        var out: [CTLine] = [], breaks: [Int] = []
        var start = 0
        while start < n, out.count < lines {
            if out.count == lines - 1 {
                let rest = CTTypesetterCreateLine(ts, CFRange(location: start, length: n - start))
                let last = truncated(rest, w, font, color)
                out.append(last)
                return (out, breaks, true, last === rest ? nil : w)
            }
            let count = CTTypesetterSuggestLineBreak(ts, start, Double(w))
            if count <= 0 { break }
            out.append(CTTypesetterCreateLine(ts, CFRange(location: start, length: count)))
            breaks.append(count)
            start += count
        }
        return (out, breaks, false, nil)
    }

    /// A small incoming-bubble tail under a bubble's lower-left corner (flipped coordinates).
    static func tailPath(bubbleBottomLeft o: CGPoint) -> CGPath {
        let t = CGMutablePath()
        t.move(to: CGPoint(x: o.x + 6, y: o.y - 6))
        t.addQuadCurve(to: CGPoint(x: o.x - 1, y: o.y + 4), control: CGPoint(x: o.x + 5, y: o.y + 2))
        t.addQuadCurve(to: CGPoint(x: o.x + 13, y: o.y - 1), control: CGPoint(x: o.x + 6, y: o.y + 3))
        t.closeSubpath()
        return t
    }

    /// The title of the host's extra search section: 11 pt semibold, secondary, at the row
    /// text's x, baseline 20 pt in a 28 pt band (to verify against Messages' search sections).
    static func sectionHeader(_ title: String, width: CGFloat, ctx: SidebarRenderContext) -> CGImage? { // nil when the bitmap cannot be allocated
        let font = uiFont(.emphasizedSystem, 11) // no force unwrap (cx-qpqs)
        let l = truncated(line(title, font, ctx.palette.secondary), width - 2 * SidebarMetrics.selectionInsetX - 10, font, ctx.palette.secondary)
        return bitmap(size: CGSize(width: max(1, width), height: 28), ctx: ctx) { g in
            draw(l, x: SidebarMetrics.selectionInsetX + 10, baseline: 20, g)
        }
    }

    // MARK: Pinned tile

    /// The avatar's rect in a tile (tile coordinates).
    static func tileAvatar(_ m: SidebarMetrics) -> CGRect {
        let d = m.pinAvatar
        return CGRect(x: ((m.tileWidth - d) / 2).rounded(), y: m.compact ? SidebarMetrics.pinTopPad / 2 : SidebarMetrics.pinTopPad, width: d, height: d)
    }

    /// A pinned tile is layers: the avatar (one bitmap at the largest pin size, scaled), the
    /// unread dot, the name and the newest-message bubble. The name and the bubble are drawn at
    /// their natural width when they fit the tile and only move when the width changes; they
    /// are redrawn for a width only when it truncates the name or wraps the bubble.
    static func tileName(_ c: ConversationSummary) -> String {
        c.isGroup ? c.title : String(c.title.split(separator: " ").first ?? Substring(c.title))
    }
    /// The natural widths of a tile's name and of its preview as one line (no bubble padding).
    static func tileNatural(_ c: ConversationSummary) -> (name: CGFloat, bubble: CGFloat) {
        let n = width(line(tileName(c), pinNameFont, CGColor(gray: 0, alpha: 1)))
        let b = width(line(c.preview.replacingOccurrences(of: "\n", with: " "), bubbleFont, CGColor(gray: 0, alpha: 1)))
        return (n, b)
    }
    /// The width a tile name bitmap is drawn for: 0 when the name fits (natural width), else the room.
    static func tileNameKeyWidth(natural: CGFloat, tileWidth: CGFloat) -> CGFloat {
        natural <= tileWidth - 8 ? 0 : (tileWidth - 8).rounded(.down)
    }
    /// The width a bubble is drawn for: 0 when the preview fits on one line, else the bubble's room.
    static func tileBubbleKeyWidth(natural: CGFloat, tileWidth: CGFloat) -> CGFloat {
        natural + 16 <= tileWidth - 6 ? 0 : (tileWidth - 6).rounded(.down)
    }
    /// The name, 16 pt tall, baseline 11 pt; `keyWidth` 0: natural width.
    static func tileNameImage(_ c: ConversationSummary, emphasized: Bool, keyWidth: CGFloat, ctx: SidebarRenderContext) -> CGImage? { // nil when the bitmap cannot be allocated
        let p = ctx.palette
        let color = emphasized ? p.selectedText : p.name
        let full = line(tileName(c), pinNameFont, color)
        let l = keyWidth > 0 ? truncated(full, keyWidth, pinNameFont, color) : full
        let w = max(1, width(l).rounded(.up))
        return bitmap(size: CGSize(width: w, height: SidebarMetrics.pinNameHeight), ctx: ctx) { g in draw(l, x: 0, baseline: 11, g) }
    }
    /// The newest unread message in a bubble (2 lines at most) with its tail at the lower left;
    /// the bitmap has 1 pt left and 5 pt below the bubble for the tail. `keyWidth` 0: one line.
    static func tileBubbleImage(_ c: ConversationSummary, keyWidth: CGFloat, ctx: SidebarRenderContext) -> CGImage? { // nil when the bitmap cannot be allocated
        let p = ctx.palette
        let lines = keyWidth > 0 ? wrapped(c.preview, bubbleFont, p.bubbleText, width: keyWidth - 16, lines: 2)
                                 : [line(c.preview.replacingOccurrences(of: "\n", with: " "), bubbleFont, p.bubbleText)]
        let bw = ((lines.map(width).max() ?? 0) + 16).rounded(.up)
        let bw2 = keyWidth > 0 ? min(keyWidth, bw) : bw
        let bh = CGFloat(lines.count) * 13 + 9
        return bitmap(size: CGSize(width: bw2 + 1, height: bh + 5), ctx: ctx) { g in
            let br = CGRect(x: 1, y: 0, width: bw2, height: bh)
            g.setFillColor(p.bubble)
            g.addPath(CGPath(roundedRect: br, cornerWidth: min(10, bh / 2), cornerHeight: min(10, bh / 2), transform: nil)); g.fillPath()
            // The tail at the lower left, toward the avatar (as an incoming bubble's; to verify).
            g.addPath(tailPath(bubbleBottomLeft: CGPoint(x: br.minX, y: br.maxY))); g.fillPath()
            for (i, l) in lines.enumerated() { draw(l, x: br.minX + 8, baseline: 13 + CGFloat(i) * 13 - 1, g) }
        }
    }

    /// The newest-message bubble of an unread tile (tile coordinates, without the tail) and its
    /// lines, where `SidebarController.configureTile` puts the bubble layer; nil in the compact list.
    static func tileBubble(_ c: ConversationSummary, metrics m: SidebarMetrics, text: CGColor = CGColor(gray: 0, alpha: 1))
        -> (rect: CGRect, lines: [CTLine])? {
        guard !m.compact else { return nil }
        let keyWidth = tileBubbleKeyWidth(natural: tileNatural(c).bubble, tileWidth: m.tileWidth)
        let lines = keyWidth > 0 ? wrapped(c.preview, bubbleFont, text, width: keyWidth - 16, lines: 2)
                                 : [line(c.preview.replacingOccurrences(of: "\n", with: " "), bubbleFont, text)]
        let bw = ((lines.map(width).max() ?? 0) + 16).rounded(.up)
        let w = keyWidth > 0 ? min(keyWidth, bw) : bw
        let bh = CGFloat(lines.count) * 13 + 9
        let ar = tileAvatar(m)
        let bottom = ar.minY + ar.height * 0.30
        return (CGRect(x: ((m.tileWidth - w) / 2).rounded(), y: max(1, bottom - bh), width: w, height: bh), lines)
    }

    /// A recent sender's avatar on a pinned group tile: 32 % of the avatar (to verify).
    static func senderDiameter(avatar d: CGFloat) -> CGFloat { (d * 0.32).rounded() }
    /// Sender `k` (0: lower left, 1: lower right, 2: upper right) centred on the avatar's edge
    /// (flipped tile coordinates; to verify).
    static func senderRect(_ k: Int, avatar ar: CGRect, diameter d: CGFloat) -> CGRect {
        let angles: [CGFloat] = [135, 45, -45]   // degrees, y down: 135 = lower left
        let a = (angles[checked: min(max(k, 0), 2)] ?? 135) * .pi / 180 // checked
        let r = ar.width / 2
        let c = CGPoint(x: ar.midX + cos(a) * r, y: ar.midY + sin(a) * r)
        return CGRect(x: (c.x - d / 2).rounded(), y: (c.y - d / 2).rounded(), width: d, height: d)
    }

    /// The 12 pt unread dot on the tile's leading edge, left of the avatar, and below the bubble
    /// (`bubble`, nil: none) so a wide bubble never covers it (cmux-next's rule, 2026-10-08).
    static func tileUnreadDot(_ m: SidebarMetrics, bubble: CGRect?) -> CGRect {
        let d: CGFloat = 12
        let ar = tileAvatar(m)
        let cx = max(d / 2 + 1, ar.minX - d / 2 - 1)
        var cy = ar.midY - ar.height * 0.25
        if let bubble { cy = max(cy, bubble.maxY + d / 2 + 3) }
        return CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
    }
}

/// The list's motion (render-server animations only; no main-thread frames). Start values are the
/// transcript's fits on real Messages (catalyst Springs.swift and springs.json), used here
/// UNVERIFIED: no reference of the list in motion exists (appkit-native/SIDEBAR-PARITY.md).
enum SidebarMotion {
    /// Off: every change shows at once (benches; a host may turn it off).
    static var enabled = true
    /// Typing bubble in: a scale spring of 0.209 s and a 0.12 s fade, both 0.05 s after the change
    /// (transcript `typing.pop`, `typing.fade`). Out: a 0.2 s fade 0.02 s after it (`typing.out`).
    static let typingInDelay: CFTimeInterval = 0.05
    static let typingPop: CFTimeInterval = 0.209
    static let typingFade: CFTimeInterval = 0.12
    static let typingOutDelay: CFTimeInterval = 0.02
    static let typingOut: CFTimeInterval = 0.2
    /// Rows and tiles moving to new places (a new message, pin, unpin, a tile drop): the transcript's
    /// external-insert move (`transcript.insert`: 0.2834 s, cubic 0.4481 0.1998 0.6216 1.0).
    static let move: CFTimeInterval = 0.2834
    static let moveCurve = CAMediaTimingFunction(controlPoints: 0.4481, 0.1998, 0.6216, 1.0)
    /// A row or tile that was not on screen before the change fades in over the move.
    static let appear: CFTimeInterval = 0.2

    static func typingIn(_ l: CALayer) {
        let now = l.convertTime(CACurrentMediaTime(), from: nil)
        let s = CASpringAnimation(perceptualDuration: typingPop, bounce: 0)
        s.keyPath = "transform.scale"
        s.fromValue = 0.0; s.toValue = 1.0
        s.beginTime = now + typingInDelay; s.fillMode = .backwards
        s.duration = s.settlingDuration
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 0.0; f.toValue = 1.0
        f.beginTime = now + typingInDelay; f.duration = typingFade; f.fillMode = .backwards
        l.add(s, forKey: "typingIn.scale")
        l.add(f, forKey: "typingIn.opacity")
    }
    /// Fades `l` out and removes it from its superlayer when the fade ends.
    static func typingOutAndRemove(_ l: CALayer) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 1.0; f.toValue = 0.0
        f.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) + typingOutDelay
        f.duration = typingOut; f.fillMode = .both; f.isRemovedOnCompletion = false
        l.add(f, forKey: "typingOut")
        CATransaction.commit()
    }
    /// What `l` shows now: its presentation while one of its animations runs, else its model
    /// (a presentation is only updated at a commit, so right after a model change it is stale).
    static func presented(_ l: CALayer) -> CALayer {
        (l.animationKeys()?.isEmpty == false ? l.presentation() : nil) ?? l
    }
    /// An additive move from `delta` (old position minus new) to the layer's model position.
    static func move(_ l: CALayer, by delta: CGPoint) {
        guard abs(delta.x) > 0.25 || abs(delta.y) > 0.25 else { return }
        let a = CABasicAnimation(keyPath: "position")
        a.isAdditive = true
        a.fromValue = NSValue(point: NSPoint(x: delta.x, y: delta.y))
        a.toValue = NSValue(point: .zero)
        a.duration = move
        a.timingFunction = moveCurve
        l.add(a, forKey: "move")
    }
    /// Animates `l` from `old` (its presented frame before the change) to its model frame, with
    /// the move timing (an additive position and a bounds animation).
    static func reframe(_ l: CALayer, from old: CGRect) {
        guard old != l.frame else { return }
        move(l, by: CGPoint(x: old.midX - l.frame.midX, y: old.midY - l.frame.midY))
        let b = CABasicAnimation(keyPath: "bounds")
        b.fromValue = NSValue(rect: CGRect(origin: l.bounds.origin, size: old.size))
        b.toValue = NSValue(rect: l.bounds)
        b.duration = move
        b.timingFunction = moveCurve
        l.add(b, forKey: "reframe")
    }
    static func appear(_ l: CALayer) {
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 0.0; f.toValue = 1.0; f.duration = appear
        l.add(f, forKey: "appear")
    }
}

/// Messages' typing bubble: a grey capsule with three dots that light up in turn, animated on
/// the render server (no main-thread frames). The dots' timing, levels and the circle tail are
/// the transcript's typing indicator, measured on real Messages (catalyst Transcript.swift
/// `startTypingDots`, RowDraw.drawTypingBubble); their use in the list, the bubble's size and
/// the light levels are UNVERIFIED (appkit-native/SIDEBAR-PARITY.md).
final class SidebarTypingLayer: CALayer {
    private let dots = (0..<3).map { _ in CALayer() }
    /// Each dot's lit copy; its opacity carries the pulse.
    private let lit = (0..<3).map { _ in CALayer() }
    /// On a pinned tile the bubble points at the avatar with the typing indicator's two circles.
    private var tail: CAShapeLayer?
    var showsTail = false {
        didSet {
            guard showsTail != oldValue else { return }
            if showsTail {
                let t = CAShapeLayer()
                t.path = Self.tailPath
                t.fillColor = backgroundColor
                t.actions = ["position": NSNull(), "path": NSNull(), "fillColor": NSNull()]
                addSublayer(t)
                tail = t
            } else {
                tail?.removeFromSuperlayer(); tail = nil
            }
        }
    }
    static let size = CGSize(width: 34, height: 20)
    /// The transcript bubble (44 x 27.5 pt) scaled to this height.
    private static let k = size.height / 27.5
    static let dotDiameter: CGFloat = 6
    static let dotPitch: CGFloat = 8
    /// The transcript's two tail circles (9 pt at the bubble's lower left, 5 pt below-left of it), scaled.
    static let tailPath: CGPath = {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: 0.5 * k, y: size.height - 7 * k, width: 9 * k, height: 9 * k))
        p.addEllipse(in: CGRect(x: -3.5 * k, y: size.height + 1 * k, width: 5 * k, height: 5 * k))
        return p
    }()
    /// Measured pulse (transcript): period 1.0 s, dots 0.247 s apart, a Gaussian of width 0.22 s.
    static let period: CFTimeInterval = 1.0
    static let phaseStep = 0.247
    static let pulseWidth = 0.22

    override init() {
        super.init()
        bounds = CGRect(origin: .zero, size: Self.size)
        cornerRadius = Self.size.height / 2
        let d = Self.dotDiameter
        for (i, (dot, hi)) in zip(dots, lit).enumerated() { // no index math
            dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            dot.cornerRadius = d / 2
            dot.position = CGPoint(x: Self.size.width / 2 + CGFloat(i - 1) * Self.dotPitch, y: Self.size.height / 2)
            hi.frame = dot.bounds
            hi.cornerRadius = d / 2
            hi.opacity = 0
            dot.addSublayer(hi)
            addSublayer(dot)
        }
        actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
    func apply(_ p: SidebarPalette, scale: CGFloat) {
        backgroundColor = p.bubble
        tail?.fillColor = p.bubble
        tail?.contentsScale = scale
        contentsScale = scale
        for d in dots { d.backgroundColor = p.typingDotDim; d.contentsScale = scale }
        for d in lit { d.backgroundColor = p.typingDot; d.contentsScale = scale }
    }
    /// The dots pulse (tests: every lit dot has its animation, or the still phase is set).
    var isPulsing: Bool { Self.stillPhase != nil || lit.allSatisfy { $0.animation(forKey: "pulse") != nil } }
    /// Still scenes: the dots stand at this phase of the pulse (0-1) instead of animating (nil: animate).
    static var stillPhase: Double?
    private static func level(_ i: Int, phase t: Double) -> Double {
        var x = t - 0.45 - Double(i) * phaseStep
        x -= x.rounded()
        return exp(-(x / pulseWidth) * (x / pulseWidth))
    }
    /// Starts the pulse once. Phase-locked to whole periods of the media clock, so every bubble
    /// in the list pulses in step and a row that scrolls back in does not restart its cycle.
    func animate() {
        if let ph = Self.stillPhase {
            for (i, d) in lit.enumerated() { d.opacity = Float(Self.level(i, phase: ph)) }
            return
        }
        let begin = (CACurrentMediaTime() / Self.period).rounded(.down) * Self.period
        for (i, d) in lit.enumerated() where d.animation(forKey: "pulse") == nil {
            let n = 60
            var values: [NSNumber] = []
            for s in 0...n { values.append(NSNumber(value: Self.level(i, phase: Double(s) / Double(n)))) }
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = values
            a.duration = Self.period
            a.repeatCount = .infinity
            a.beginTime = begin
            a.calculationMode = .linear
            a.isRemovedOnCompletion = false
            d.add(a, forKey: "pulse")
        }
    }
}

/// Text measurement per conversation (the name line and the preview's typesetter), shared by
/// every width: a live resize only breaks lines again. Locked (render queue and main).
final class SidebarTextCache {
    struct Measured {
        let name: CTLine
        let nameColor: CGColor
        let preview: CTTypesetter?
        let previewLength: Int
        let secondary: CGColor
    }
    private struct Key: Hashable { var id: ConversationID; var version: Int; var emphasized: Bool; var generation: Int }
    private var map: [Key: Measured] = [:]
    private var order: [Key] = []
    private let lock = NSLock()
    static let capacity = 600

    func measure(_ c: ConversationSummary, emphasized: Bool, palette p: SidebarPalette, generation: Int) -> Measured {
        let k = Key(id: c.id, version: c.version, emphasized: emphasized, generation: generation)
        lock.lock()
        if let m = map[k] { lock.unlock(); return m }
        lock.unlock()
        let nameColor = emphasized ? p.selectedText : p.name
        let secondary = emphasized ? p.selectedText.copy(alpha: 0.82) ?? p.selectedText : p.secondary // no force unwrap
        let text = SidebarStrings.preview(c)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): SidebarDraw.previewFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): secondary])
        let m = Measured(name: SidebarDraw.line(c.title, SidebarDraw.nameFont, nameColor), nameColor: nameColor,
                         preview: c.typing ? nil : CTTypesetterCreateWithAttributedString(attr), previewLength: attr.length, secondary: secondary)
        lock.lock()
        if map[k] == nil { order.append(k) }
        map[k] = m
        if order.count > Self.capacity {
            for old in order.prefix(Self.capacity / 3) { map[old] = nil }
            order.removeFirst(Self.capacity / 3)
        }
        lock.unlock()
        return m
    }
    func removeAll() { lock.lock(); map.removeAll(); order.removeAll(); lock.unlock() }
}
