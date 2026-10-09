#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Colours of markdown elements on one bubble. Every colour derives from the
/// bubble's own text colour (so incoming grey, outgoing blue, light and dark keep
/// their contrast), except incoming links (the transcript's link blue) and syntax
/// colours (Xcode's default dark or light theme on incoming, tints of white on blue).
struct MDPalette {
    var text: UIColor
    var secondary: UIColor
    var marker: UIColor
    var link: UIColor
    var inset: UIColor          // code block and inline code background
    var line: UIColor           // table grid, rules
    var header: UIColor         // table header fill
    var bar: UIColor            // quote bar
    var check: UIColor          // checked box fill
    var checkMark: UIColor
    var tokens: [MDToken: UIColor]

    /// Relative luminance of any colour: converted to device RGB first (else grey, else light
    /// text, the dark bubble), HDR components clamped to 0...1. Never reads components of an
    /// unconverted colour.
    static func luminance(_ c: UIColor) -> CGFloat {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0.9 }
        func k(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
        return 0.2126 * k(r) + 0.7152 * k(g) + 0.0722 * k(b)
        #else
        if let rgb = c.usingColorSpace(.deviceRGB) {
            func k(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
            return 0.2126 * k(rgb.redComponent) + 0.7152 * k(rgb.greenComponent) + 0.0722 * k(rgb.blueComponent)
        }
        if let gray = c.usingColorSpace(.genericGray) { return min(1, max(0, gray.whiteComponent)) }
        return 0.9
        #endif
    }

    /// Cached per bubble side and palette generation (a theme or appearance change makes new ones).
    private static var cache: [Int: MDPalette] = [:]
    private static let cacheLock = NSLock()
    static func palette(outgoing: Bool) -> MDPalette {
        let k = Fixture.paletteGeneration &* 4 &+ (Fixture.lightAppearance ? 2 : 0) &+ (outgoing ? 1 : 0)
        let text = outgoing ? Fixture.outgoingText : Fixture.incomingText
        cacheLock.lock()
        // The text colour can change without a new generation (an elevated window): compare it.
        if let p = cache[k], p.text.isEqual(text) { cacheLock.unlock(); return p }
        cacheLock.unlock()
        let p = make(outgoing: outgoing)
        cacheLock.lock()
        if cache.count > 8 { cache.removeAll() }
        cache[k] = p
        cacheLock.unlock()
        return p
    }

    static func make(outgoing: Bool) -> MDPalette {
        let text = outgoing ? Fixture.outgoingText : Fixture.incomingText
        // getWhite is valid only for a grey colour: a host theme's sRGB (or HDR sRGB) text
        // colour threw an NSException on the render queue. Luminance after converting.
        let darkBubble = MDPalette.luminance(text) > 0.5
        func t(_ a: CGFloat) -> UIColor { text.withAlphaComponent(a) }
        let link = outgoing ? Fixture.outgoingText : UIColor(red: 0.27, green: 0.55, blue: 1, alpha: 1)
        var tokens: [MDToken: UIColor] = [:]
        if outgoing {
            // On blue: tints of white and pale warm colours (contrast >= 4.5:1 on the deepest blue).
            tokens = [.keyword: UIColor(white: 1, alpha: 1), .string: Fixture.p3(255, 236, 170), .comment: UIColor(white: 1, alpha: 0.66),
                      .number: Fixture.p3(255, 214, 180), .type: Fixture.p3(214, 240, 255), .added: Fixture.p3(196, 255, 200),
                      .removed: Fixture.p3(255, 205, 205), .meta: UIColor(white: 1, alpha: 0.7)]
        } else if darkBubble {
            // Xcode Default (Dark), lifted where the grey bubble needs it.
            tokens = [.keyword: Fixture.p3(255, 122, 178), .string: Fixture.p3(255, 129, 112), .comment: Fixture.p3(150, 162, 173),
                      .number: Fixture.p3(217, 201, 124), .type: Fixture.p3(93, 216, 255), .added: Fixture.p3(110, 220, 120),
                      .removed: Fixture.p3(255, 120, 120), .meta: Fixture.p3(150, 162, 173)]
        } else {
            tokens = [.keyword: Fixture.p3(155, 35, 147), .string: Fixture.p3(196, 26, 22), .comment: Fixture.p3(93, 108, 121),
                      .number: Fixture.p3(28, 0, 207), .type: Fixture.p3(11, 79, 121), .added: Fixture.p3(30, 120, 40),
                      .removed: Fixture.p3(180, 30, 30), .meta: Fixture.p3(93, 108, 121)]
        }
        return MDPalette(text: text, secondary: t(0.78), marker: t(0.72), link: link,
                         inset: outgoing ? UIColor(white: 0, alpha: 0.2) : darkBubble ? UIColor(white: 0, alpha: 0.24) : UIColor(white: 0, alpha: 0.06),
                         line: t(0.24), header: t(0.07), bar: t(0.38),
                         check: outgoing ? Fixture.outgoingText : link, checkMark: outgoing ? Fixture.outgoing : .white, tokens: tokens)
    }
}

enum MarkdownDraw {
    enum Mode { case all, skipScrollable, region(Int) }

    /// Draws a markdown body. `body` is the bubble rect in the context (its origin is
    /// the layout's origin). `offsets`: horizontal scroll per region.
    /// `slice`: body-local y range of a tile (long messages): boxes are clipped to it and only text
    /// lines whose slot starts in it are drawn (whole, so glyphs overflow into the next tile's room,
    /// which does not draw them again).
    static func draw(_ ctx: CGContext, _ md: MarkdownLayout, body: CGRect, outgoing: Bool, offsets: [Int: CGFloat] = [:], mode: Mode = .all,
                     slice: Range<CGFloat>? = nil) {
        let pal = MDPalette.palette(outgoing: outgoing)
        ctx.saveGState()
        ctx.translateBy(x: body.minX, y: body.minY)
        if case let .region(r) = mode {
            // A region alone, in content coordinates (overlay bitmaps): origin = region's left/top.
            let reg = md.regions[r]
            ctx.translateBy(x: -reg.frame.minX, y: -reg.frame.minY)
            drawContent(ctx, md, region: r, pal: pal)
            ctx.restoreGState()
            return
        }
        drawContent(ctx, md, region: -1, pal: pal, slice: slice)
        for (i, reg) in md.regions.enumerated() {
            if case .skipScrollable = mode, MarkdownOverlay.usesOverlay(reg) { continue }
            if let s = slice, reg.frame.maxY <= s.lowerBound || reg.frame.minY >= s.upperBound { continue }
            let off = min(reg.maxOffset, max(0, offsets[i] ?? 0))
            ctx.saveGState()
            ctx.clip(to: reg.frame)
            if reg.kind == .code { roundedClip(ctx, reg.frame, 6) }
            ctx.translateBy(x: -off, y: 0)
            drawContent(ctx, md, region: i, pal: pal, slice: slice)
            ctx.restoreGState()
            if reg.scrollable, slice.map({ reg.frame.maxY - 4 >= $0.lowerBound && reg.frame.maxY - 4 < $0.upperBound }) ?? true {
                drawIndicator(ctx, reg, offset: off, pal: pal)
            }
        }
        ctx.restoreGState()
    }

    static func roundedClip(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
    }

    /// A scrollable block's position: a short bar at its bottom edge.
    static func drawIndicator(_ ctx: CGContext, _ reg: MDRegion, offset: CGFloat, pal: MDPalette) {
        let track = reg.frame.insetBy(dx: 6, dy: 0)
        let frac = reg.frame.width / reg.contentWidth
        let w = max(18, track.width * frac)
        let x = track.minX + (track.width - w) * (reg.maxOffset > 0 ? offset / reg.maxOffset : 0)
        let r = CGRect(x: x, y: reg.frame.maxY - 4, width: w, height: 2.5)
        ctx.setFillColor(pal.text.withAlphaComponent(0.32).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1, cornerHeight: 1, transform: nil))
        ctx.fillPath()
    }

    static func drawContent(_ ctx: CGContext, _ md: MarkdownLayout, region: Int, pal: MDPalette, slice: Range<CGFloat>? = nil) {
        // A tile slice: boxes clipped to it exactly (adjacent tiles meet without double alpha).
        if let s = slice {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: -100_000, y: s.lowerBound, width: 200_000, height: s.upperBound - s.lowerBound))
        }
        let boxes = slice.map { s in md.boxes.filter { $0.rect.maxY > s.lowerBound - 1 && $0.rect.minY < s.upperBound + 1 } } ?? md.boxes
        // Fills under text, then text, then lines over fills.
        for b in boxes where b.region == region {
            switch b.kind {
            case .codeBlock:
                ctx.setFillColor(pal.inset.cgColor)
                ctx.addPath(CGPath(roundedRect: b.rect, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
            case .inlineCode:
                ctx.setFillColor(pal.inset.cgColor)
                ctx.addPath(CGPath(roundedRect: b.rect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)); ctx.fillPath()
            case .tableHeader:
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: CGRect(x: b.rect.minX, y: b.rect.minY, width: b.rect.width, height: b.rect.height + 6), cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.clip()
                ctx.setFillColor(pal.header.cgColor); ctx.fill(b.rect)
                ctx.restoreGState()
            case .quoteBar:
                ctx.setFillColor(pal.bar.cgColor)
                ctx.addPath(CGPath(roundedRect: b.rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); ctx.fillPath()
            default: break
            }
        }
        if let s = slice { ctx.restoreGState()
            for f in md.frags where f.region == region && f.origin.y >= s.lowerBound - 0.01 && f.origin.y < s.upperBound - 0.01 { drawFrag(ctx, f, pal) }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: -100_000, y: s.lowerBound, width: 200_000, height: s.upperBound - s.lowerBound))
        } else {
            for f in md.frags where f.region == region { drawFrag(ctx, f, pal) }
        }
        for b in boxes where b.region == region {
            switch b.kind {
            case .gridH, .gridV, .rule:
                ctx.setFillColor(pal.line.cgColor); ctx.fill(b.rect)
            case .strike:
                ctx.setFillColor(pal.text.cgColor); ctx.fill(b.rect)
            case .tableBorder:
                ctx.setStrokeColor(pal.line.cgColor); ctx.setLineWidth(0.5)
                ctx.addPath(CGPath(roundedRect: b.rect.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.strokePath()
            case let .checkbox(checked):
                let path = CGPath(roundedRect: b.rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                if checked {
                    ctx.setFillColor(pal.check.cgColor); ctx.addPath(path); ctx.fillPath()
                    ctx.setStrokeColor(pal.checkMark.cgColor); ctx.setLineWidth(1.6); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    let r = b.rect
                    ctx.move(to: CGPoint(x: r.minX + 2.6, y: r.midY + 0.2))
                    ctx.addLine(to: CGPoint(x: r.minX + 4.6, y: r.maxY - 2.6))
                    ctx.addLine(to: CGPoint(x: r.maxX - 2.4, y: r.minY + 2.8))
                    ctx.strokePath()
                } else {
                    ctx.setStrokeColor(pal.marker.cgColor); ctx.setLineWidth(1)
                    ctx.addPath(CGPath(roundedRect: b.rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)); ctx.strokePath()
                }
            default: break
            }
        }
        if slice != nil { ctx.restoreGState() }
    }

    static func drawFrag(_ ctx: CGContext, _ f: MDFrag, _ pal: MDPalette) {
        guard f.attr.length > 0 else { return }
        let a = NSMutableAttributedString(attributedString: f.attr)
        let full = NSRange(location: 0, length: a.length)
        let base: UIColor
        switch f.role {
        case .quote: base = pal.secondary
        case .marker, .more: base = pal.marker
        default: base = pal.text
        }
        a.addAttribute(.foregroundColor, value: base, range: full)
        a.enumerateAttribute(.mdRole, in: full) { v, r, _ in
            if let raw = v as? UInt8, raw == MDRole.quote.rawValue { a.addAttribute(.foregroundColor, value: pal.secondary, range: r) }
        }
        a.enumerateAttribute(.mdToken, in: full) { v, r, _ in
            if let raw = v as? UInt8, let t = MDToken(rawValue: raw), let c = pal.tokens[t] { a.addAttribute(.foregroundColor, value: c, range: r) }
        }
        a.enumerateAttribute(.link, in: full) { v, r, _ in
            guard v != nil else { return }
            a.addAttributes([.foregroundColor: pal.link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
        }
        // CoreText draws NSLink runs blue on its own in some hosts: drop the attribute for drawing.
        a.removeAttribute(.link, range: full)
        let line = CTLineCreateWithAttributedString(a)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: f.origin.x, y: f.origin.y + f.baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// Copy representations (MarkdownGeometry.pasteboardItems).
enum MarkdownCopy {
    /// Plain text of a display range: the display string itself (code exact, table
    /// cells tab-separated, list markers as text).
    static func plain(_ md: MarkdownLayout, _ r: NSRange) -> String { md.substring(r) }

    /// HTML of the blocks that intersect `r` (whole blocks: a table copies as a table).
    static func html(_ md: MarkdownLayout, _ r: NSRange) -> String? {
        var out = ""
        let ns = md.plain as NSString
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func text(_ range: NSRange) -> String {
            let inter = NSIntersectionRange(range, r)
            guard inter.length > 0 else { return "" }
            return esc(ns.substring(with: inter))
        }
        func emit(_ n: MDAXNode) {
            guard NSIntersectionRange(n.range, r).length > 0 || (n.range.length == 0 && NSLocationInRange(n.range.location, r)) else { return }
            switch n.kind {
            case .paragraph: out += "<p>" + text(n.range).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
            case let .heading(l): out += "<h\(l)>" + text(n.range) + "</h\(l)>"
            case let .code(lang): out += "<pre><code\(lang.isEmpty ? "" : " class=\"language-\(esc(lang))\"")>" + text(n.range) + "</code></pre>"
            case .quote: out += "<blockquote>"; n.children.forEach(emit); out += "</blockquote>"
            case let .list(ordered): out += ordered ? "<ol>" : "<ul>"; n.children.forEach(emit); out += ordered ? "</ol>" : "</ul>"
            case .item:
                out += "<li>"
                if n.children.isEmpty { out += text(n.range) } else { n.children.forEach(emit) }
                out += "</li>"
            case .table:
                // Whole table (TSV in plain text, a real table here).
                out += "<table>"
                for (i, row) in n.children.enumerated() {
                    out += "<tr>"
                    for c in row.children { let tag = i == 0 ? "th" : "td"; out += "<\(tag)>" + esc(ns.substring(with: c.range)) + "</\(tag)>" }
                    out += "</tr>"
                }
                out += "</table>"
            case .rule: out += "<hr>"
            default: break
            }
        }
        md.ax.forEach(emit)
        return out.isEmpty ? nil : "<meta charset=\"utf-8\">" + out
    }
}
