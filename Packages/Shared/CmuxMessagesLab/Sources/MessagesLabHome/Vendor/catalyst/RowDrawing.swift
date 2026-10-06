#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Row drawing, independent of views (thread safe; the loader queue and the
/// bitmap renderer call it).
enum RowDraw {
    /// Rows are drawn with this margin above and below the content (tails, badges).
    /// Padding above and below the content in row bitmaps and cells (tails,
    /// tapback badges reach 22 pt above a bubble).
    static let margin: CGFloat = 24

    static func receiptParts(_ bold: String, _ rest: String) -> [(String, UIFont, UIColor)] {
        [(bold, .systemFont(ofSize: Fixture.captionSize, weight: .semibold), Fixture.secondaryText),
         (rest, .systemFont(ofSize: Fixture.captionSize), Fixture.secondaryText)]
    }
    static let captionKern: CGFloat = -0.03

    /// Horizontal span that needs pixels (cell bitmaps stay small).
    static func drawSpan(_ spec: RowSpec) -> ClosedRange<CGFloat> {
        if case .typing = spec.kind { return 0...min(spec.width, 140) }
        if case .receipt = spec.kind { return max(0, spec.metrics.receiptRight - 170)...spec.width }
        guard case let .part(p) = spec.kind else { return 0...spec.width }
        let x = p.outgoing ? spec.metrics.rightEdge - p.size.width : Fixture.leftEdge
        // Media carry a save button 14 + 28 pt beside them.
        var media = false
        if case let .attachment(a) = p.part, a.kind == "image" || a.kind == "video" { media = true }
        let extra: CGFloat = media ? 46 : 0
        return max(0, x - 36 - (p.outgoing ? extra : 0))...min(spec.width, x + p.size.width + 20 + (p.outgoing ? 0 : extra))
    }

    /// Body rect of a part row in row coordinates (window width, margin above).
    static func bodyRect(_ spec: RowSpec) -> CGRect {
        guard case let .part(p) = spec.kind else { return .zero }
        let x = p.outgoing ? spec.metrics.rightEdge - p.size.width : Fixture.leftEdge
        return CGRect(x: x, y: margin, width: p.size.width, height: p.bodySize.height)
    }

    /// Outgoing shapes whose fill is the window-position gradient (a layer).
    static func needsFill(_ spec: RowSpec) -> Bool {
        guard case let .part(p) = spec.kind, p.outgoing else { return false }
        switch p.part {
        case .text: return true
        case let .attachment(a): return !["image", "video"].contains(a.kind)
        default: return false
        }
    }

    /// Everything a row draws. `windowY = .nan` leaves the outgoing bubble
    /// fill to the cell's gradient layer.
    static func drawStatic(_ spec: RowSpec, _ ctx: CGContext, windowY: CGFloat, highlight: Bool = false) {
        let top = margin
        let m = spec.metrics
        switch spec.kind {
        case let .separator(bold, rest):
            let parts = receiptParts(bold, " " + rest)
            let w = parts.reduce(0) { $0 + TextDraw.width($1.0, font: $1.1, kern: captionKern) }
            var x = m.centerX - w / 2
            for (s, f, c) in parts {
                TextDraw.line(s, font: f, color: c, x: x, baseline: top + 27.5, in: ctx, kern: captionKern)
                x += TextDraw.width(s, font: f, kern: captionKern)
            }
        case let .unsent(outgoing):
            let s = outgoing ? Strings.unsentMine : Strings.unsentTheirs
            let f = UIFont.systemFont(ofSize: 11)
            let w = TextDraw.width(s, font: f)
            TextDraw.line(s, font: f, color: Fixture.secondaryText, x: m.centerX + 0.1 - w / 2, baseline: top + 12, in: ctx)
        case let .label(text, outgoing, color):
            let f = UIFont.systemFont(ofSize: 10, weight: .medium)
            let c: UIColor = color == .failure ? UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
                : color == .link ? UIColor(red: 0.2, green: 0.55, blue: 1, alpha: 1) : Fixture.secondaryText
            let w = TextDraw.width(text, font: f)
            TextDraw.line(text, font: f, color: c, x: outgoing ? m.receiptRight - w : Fixture.labelLeft, baseline: top + 11, in: ctx)
        case let .replies(count, _, outgoing):
            let f = UIFont.systemFont(ofSize: 10, weight: .semibold)
            let s = Strings.replies(count)
            let w = TextDraw.width(s, font: f, kern: captionKern)
            TextDraw.line(s, font: f, color: PreviewStyle.repliesBlue,
                          x: outgoing ? m.receiptRight - w : Fixture.labelLeft, baseline: top + 14, in: ctx, kern: captionKern)
        case let .part(p):
            let x = p.outgoing ? m.rightEdge - p.size.width : Fixture.leftEdge
            PartRenderer.draw(ctx, row: p, body: CGRect(x: x, y: margin, width: p.size.width, height: p.bodySize.height),
                              windowY: windowY, highlight: highlight)
        case let .receipt(bold, rest):
            drawReceipt(ctx, bold, rest, receiptRight: m.receiptRight, top: top)
        case .typing:
            drawTypingBubble(ctx, top: top + 4)
        case let .threadPreview(pv):
            PartRenderer.drawThreadPreview(ctx, pv, top: top, width: spec.width)
        }
    }

    static func drawReceipt(_ ctx: CGContext, _ bold: String, _ rest: String, receiptRight: CGFloat, top: CGFloat) {
        let parts = receiptParts(bold, rest.isEmpty ? "" : " " + rest.trimmingCharacters(in: .whitespaces))
        let w = parts.reduce(0) { $0 + TextDraw.width($1.0, font: $1.1, kern: captionKern) }
        var x = receiptRight - w
        for (s, f, c) in parts {
            TextDraw.line(s, font: f, color: c, x: x, baseline: top + 14, in: ctx, kern: captionKern)
            x += TextDraw.width(s, font: f, kern: captionKern)
        }
    }
    static func receiptWidth(_ bold: String, _ rest: String) -> CGFloat {
        receiptParts(bold, rest.isEmpty ? "" : " " + rest.trimmingCharacters(in: .whitespaces))
            .reduce(0) { $0 + TextDraw.width($1.0, font: $1.1, kern: captionKern) }
    }

    /// The typing bubble without its dots (dots are layers that animate).
    static let typingBubble = CGRect(x: 20, y: margin + 4, width: 44, height: 27.5)
    static func drawTypingBubble(_ ctx: CGContext, top: CGFloat) {
        let b = CGRect(x: 20, y: top, width: 44, height: 27.5)
        Fixture.incoming.setFill()
        UIBezierPath(roundedRect: b, cornerRadius: b.height / 2).fill()
        UIBezierPath(ovalIn: CGRect(x: 20.5, y: b.maxY - 7, width: 9, height: 9)).fill()
        UIBezierPath(ovalIn: CGRect(x: 16.5, y: b.maxY + 1, width: 5, height: 5)).fill()
    }
    static func typingDotCenter(_ i: Int) -> CGPoint {
        let b = typingBubble
        return CGPoint(x: b.minX + 12.25 + CGFloat(i) * 9.5, y: b.midY)
    }
}

/// Drawing for every part type.
enum PartRenderer {
    static func draw(_ ctx: CGContext, row p: PartRow, body: CGRect, windowY: CGFloat, highlight: Bool) {
        switch p.part {
        case .text:
            let lines = p.text.map { tl in tl.lines.map { _ in "" } } ?? []
            BubbleView.drawBubble(ctx, body: body, lines: [], outgoing: p.outgoing, tail: p.tail, windowY: windowY)
            _ = lines
            if let tl = p.text { drawText(ctx, tl, in: body, outgoing: p.outgoing) }
        case let .link(url, title, site, image, _) where Sizing.linkPending(title: title, site: site, image: image):
            // Messages' loading card: a grey rounded square, an activity spinner
            // and the domain under it (link-url-and-text take, t+0.6-1.9 s).
            let light = Fixture.lightAppearance
            (light ? Fixture.p3(233, 233, 235) : Fixture.incoming).setFill()
            UIBezierPath(roundedRect: body, cornerRadius: 15).fill()
            let c = CGPoint(x: body.midX, y: body.midY - 6)
            for k in 0..<8 {
                let a = CGFloat(k) * .pi / 4
                let p = UIBezierPath()
                p.move(to: CGPoint(x: c.x + 4.5 * cos(a), y: c.y + 4.5 * sin(a)))
                p.addLine(to: CGPoint(x: c.x + 9 * cos(a), y: c.y + 9 * sin(a)))
                p.lineWidth = 2; p.lineCapStyle = .round
                UIColor(white: light ? 0 : 1, alpha: 0.25 + 0.6 * CGFloat(k) / 7).setStroke(); p.stroke()
            }
            let host = URL(string: url).map(TextParts.host) ?? url
            let f = UIFont.systemFont(ofSize: 10)
            TextDraw.line(host, font: f, color: Fixture.secondaryText, x: body.midX - TextDraw.width(host, font: f) / 2, baseline: c.y + 24, in: ctx)
        case let .link(_, title, site, image, theme):
            // A light appearance draws every card light; a dark one keeps the card's
            // own theme (a card with no image is dark).
            drawLink(ctx, body: body, title: title ?? "", site: site ?? "", image: image,
                     dark: !Fixture.lightAppearance && (theme == "dark" || image == nil),
                     tail: p.tail, outgoing: p.outgoing)
        case let .attachment(a):
            drawAttachment(ctx, a, body: body, row: p, windowY: windowY)
        case let .location(lat, lon, title, subtitle):
            if let img = Images.mapSnapshot(lat, lon) {
                drawMapSnapshot(ctx, img, body: body, caption: title ?? "", tail: p.tail, outgoing: p.outgoing)
            } else {
                drawLocation(ctx, body: body, title: title ?? "", subtitle: subtitle ?? "", tail: p.tail, outgoing: p.outgoing)
            }
        }
        if highlight {
            UIColor(white: 1, alpha: 0.12).setFill()
            BubblePath.make(body: body, outgoing: p.outgoing, tail: p.tail).fill()
        }
        if p.failed {
            let c = CGPoint(x: body.minX - 14, y: body.midY)
            UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)).fill()
            let f = UIFont.systemFont(ofSize: 12, weight: .bold)
            TextDraw.line("!", font: f, color: .white, x: c.x - TextDraw.width("!", font: f) / 2, baseline: c.y + 4.5, in: ctx)
        }
        drawReactions(ctx, p.reactions, body: body, outgoing: p.outgoing)
    }

    static func drawText(_ ctx: CGContext, _ tl: TextLayout, in body: CGRect, outgoing: Bool) {
        let color = outgoing ? Fixture.outgoingText : Fixture.incomingText
        // An outgoing link is the bubble's text colour (white; a themed host's own colour).
        let link = outgoing ? Fixture.outgoingText : UIColor(red: 0.27, green: 0.55, blue: 1, alpha: 1)
        let attr = tl.attributed(color: color, linkColor: link)
        for (i, line) in tl.lines.enumerated() where line.range.length > 0 {
            let l = CTLineCreateWithAttributedString(attr.attributedSubstring(from: line.range))
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: body.minX + Fixture.bubblePadX, y: body.minY + Fixture.textBaseline + tl.lineOffset(i, hard: outgoing ? TextLayout.hardBreakAdvance : Fixture.lineHeight))
            CTLineDraw(l, ctx)
            ctx.restoreGState()
        }
    }

    static func drawLink(_ ctx: CGContext, body card: CGRect, title: String, site: String, image: String?, dark: Bool,
                         tail: Bool, outgoing: Bool) {
        let (_, ih) = Sizing.linkImageSize(image)
        let captionColor = dark ? (image == nil ? UIColor(white: 49 / 255, alpha: 1) : UIColor(red: 35 / 255, green: 55 / 255, blue: 68 / 255, alpha: 1))
            : Fixture.lightAppearance ? Fixture.p3(233, 233, 235)   // light appearance: Messages' light incoming grey
            : UIColor(white: 235 / 255, alpha: 1)   // light caption: 235, title 36, site 118 (lossless still)
        let shape = BubblePath.make(body: card, outgoing: outgoing, tail: tail)
        ctx.saveGState()
        captionColor.setFill()
        shape.fill()
        shape.addClip()
        if let image, let img = Images.load(image) {
            // Aspect fill; bottom aligned so the image meets the caption.
            let h = card.width * img.size.height / img.size.width
            img.draw(in: CGRect(x: card.minX, y: card.minY + ih - h, width: card.width, height: h))
        }
        ctx.restoreGState()
        let titleColor = dark ? UIColor(white: 0.93, alpha: 1) : UIColor(white: 36 / 255, alpha: 1)
        let siteColor = dark ? UIColor(white: 0.68, alpha: 1) : UIColor(white: 118 / 255, alpha: 1)
        var y = card.minY + ih + 18
        for s in Sizing.linkTitleLines(title, width: card.width) {
            TextDraw.line(s, font: Sizing.linkTitleFont, color: titleColor, x: card.minX + 10, baseline: y, in: ctx, kern: -0.005)
            y += 12
        }
        TextDraw.line(site, font: .systemFont(ofSize: 10), color: siteColor, x: card.minX + 10.25, baseline: y + 2.8, in: ctx, kern: -0.03)
    }

    static func drawAttachment(_ ctx: CGContext, _ a: Attachment, body: CGRect, row p: PartRow, windowY: CGFloat) {
        let shape = BubblePath.make(body: body, outgoing: p.outgoing, tail: p.tail)
        switch a.kind {
        case "image", "video":
            ctx.saveGState()
            shape.addClip()
            UIColor(white: 0.2, alpha: 1).setFill()
            ctx.fill(body)
            if let ref = a.kind == "video" ? (a.poster ?? a.asset) : a.asset, let img = Images.load(ref) {
                let s = max(body.width / img.size.width, body.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                img.draw(in: CGRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h))
            }
            ctx.restoreGState()
            if a.kind == "video" {
                // macOS 26: a translucent dark disc with a light play glyph, no duration badge.
                UIColor(white: 0, alpha: 0.5).setFill()
                UIBezierPath(ovalIn: CGRect(x: body.midX - 16, y: body.midY - 16, width: 32, height: 32)).fill()
                let tri = UIBezierPath()
                tri.move(to: CGPoint(x: body.midX - 5, y: body.midY - 8))
                tri.addLine(to: CGPoint(x: body.midX + 9, y: body.midY))
                tri.addLine(to: CGPoint(x: body.midX - 5, y: body.midY + 8))
                tri.close()
                UIColor(white: 1, alpha: 0.85).setFill()
                tri.fill()
            }
            // cmux: an undelivered photo shows only the red badge (Messages); the button sat under it.
            if !p.failed { drawSaveButton(ctx, body: body, outgoing: p.outgoing) }
        case "voiceMemo":
            fillBubble(ctx, shape, outgoing: p.outgoing, windowY: windowY)
            let fg: UIColor = p.outgoing ? Fixture.outgoingText : Fixture.incomingText  // cmux: themed (white by default)
            fg.setFill()
            UIBezierPath(ovalIn: CGRect(x: body.minX + 8, y: body.midY - 11, width: 22, height: 22)).fill()
            let tri = UIBezierPath()
            tri.move(to: CGPoint(x: body.minX + 16.5, y: body.midY - 5.5))
            tri.addLine(to: CGPoint(x: body.minX + 24.5, y: body.midY))
            tri.addLine(to: CGPoint(x: body.minX + 16.5, y: body.midY + 5.5))
            tri.close()
            (p.outgoing ? Fixture.outgoing : Fixture.incoming).setFill()
            tri.fill()
            fg.withAlphaComponent(0.85).setFill()
            for i in 0..<30 {
                let v = 0.25 + 0.75 * abs(sin(Double(i) * 1.7) * cos(Double(i) * 0.45))
                let h = CGFloat(v) * 18
                UIBezierPath(roundedRect: CGRect(x: body.minX + 38 + CGFloat(i) * 3.6, y: body.midY - h / 2, width: 2, height: max(2, h)),
                             cornerRadius: 1).fill()
            }
            let d = Format.duration(a.durationSeconds ?? 0)
            TextDraw.line(d, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: fg, x: body.maxX - 36,
                          baseline: body.midY + 4, in: ctx)
        default:
            fillBubble(ctx, shape, outgoing: p.outgoing, windowY: windowY)
            let fg: UIColor = p.outgoing ? Fixture.outgoingText : Fixture.incomingText  // cmux: themed (white by default)
            let icon = CGRect(x: body.minX + 10, y: body.minY + 10, width: 28, height: 36)
            if a.kind == "contact" {
                UIColor(white: 0.55, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: body.minX + 9, y: body.minY + 10, width: 36, height: 36)).fill()
                let initial = String(a.fileName.prefix(1)).uppercased()
                let f = UIFont.systemFont(ofSize: 17, weight: .semibold)
                TextDraw.line(initial, font: f, color: .white, x: body.minX + 27 - TextDraw.width(initial, font: f) / 2,
                              baseline: body.minY + 34, in: ctx)
                let name = (a.fileName as NSString).deletingPathExtension
                TextDraw.line(name, font: .systemFont(ofSize: 13, weight: .semibold), color: fg, x: body.minX + 54, baseline: body.minY + 33, in: ctx)
                let chev = UIBezierPath()
                chev.move(to: CGPoint(x: body.maxX - 18, y: body.midY - 5))
                chev.addLine(to: CGPoint(x: body.maxX - 13, y: body.midY))
                chev.addLine(to: CGPoint(x: body.maxX - 18, y: body.midY + 5))
                chev.lineWidth = 1.6
                fg.withAlphaComponent(0.6).setStroke()
                chev.stroke()
            } else {
                drawFileRow(ctx, a, body: body, fg: fg)
            }
        }
    }

    /// A file or audio row (measured, macOS 26): 275 x 89.5, the icon centred
    /// at x 22.5 (document 39 x 52) or x 12 (audio 60 x 60), the name 13 pt
    /// semibold at +43 and "<Kind> · <size>" 11 pt at +58.5 from the top, both
    /// at x 84.5.
    static func drawFileRow(_ ctx: CGContext, _ a: Attachment, body: CGRect, fg: UIColor) {
        let ext = (a.fileName as NSString).pathExtension.lowercased()
        let paper = UIColor(white: 0.93, alpha: 1)
        if a.kind == "audio" {
            let icon = CGRect(x: body.minX + 12, y: body.midY - 30, width: 60, height: 60)
            paper.setFill()
            UIBezierPath(roundedRect: icon, cornerRadius: 4).fill()
            let cfg = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
            if let note = UIImage(systemName: "music.note", withConfiguration: cfg)?.withTintColor(UIColor(white: 0.62, alpha: 1), renderingMode: .alwaysOriginal) {
                let s = note.size
                note.draw(in: CGRect(x: icon.midX - s.width / 2, y: icon.midY - s.height / 2, width: s.width, height: s.height))
            }
        } else {
            let icon = CGRect(x: body.minX + 22.5, y: body.midY - 26, width: 39, height: 52)
            let fold: CGFloat = 10
            let doc = UIBezierPath()
            doc.move(to: CGPoint(x: icon.minX, y: icon.minY))
            doc.addLine(to: CGPoint(x: icon.maxX - fold, y: icon.minY))
            doc.addLine(to: CGPoint(x: icon.maxX, y: icon.minY + fold))
            doc.addLine(to: CGPoint(x: icon.maxX, y: icon.maxY))
            doc.addLine(to: CGPoint(x: icon.minX, y: icon.maxY))
            doc.close()
            paper.setFill()
            doc.fill()
            UIColor(white: 0.78, alpha: 1).setFill()
            let corner = UIBezierPath()
            corner.move(to: CGPoint(x: icon.maxX - fold, y: icon.minY))
            corner.addLine(to: CGPoint(x: icon.maxX - fold, y: icon.minY + fold))
            corner.addLine(to: CGPoint(x: icon.maxX, y: icon.minY + fold))
            corner.close()
            corner.fill()
            let ink = UIColor(white: 0.6, alpha: 1)
            ink.setFill()
            if ext == "zip" {
                for i in 0..<6 { ctx.fill(CGRect(x: icon.midX - (i % 2 == 0 ? 2.5 : 0), y: icon.minY + 4 + CGFloat(i) * 3, width: 2.5, height: 2)) }
            } else {
                ctx.fill(CGRect(x: icon.minX + 9, y: icon.minY + 17, width: 8, height: 7))
                for (i, w) in ([11, 11, 21, 21] as [CGFloat]).enumerated() {
                    ctx.fill(CGRect(x: icon.minX + (i < 2 ? 19 : 9), y: icon.minY + 17 + CGFloat(i) * 4.5 + (i >= 2 ? 1 : 0), width: w, height: 1.5))
                }
            }
            let label = ext.uppercased()
            let f = UIFont.systemFont(ofSize: 7, weight: .regular)
            TextDraw.line(label, font: f, color: UIColor(white: 0.6, alpha: 1), x: icon.midX - TextDraw.width(label, font: f) / 2,
                          baseline: icon.maxY - 5, in: ctx)
        }
        let nameFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        var name = a.fileName
        while TextDraw.width(name, font: nameFont) > body.width - 100, name.count > 4 { name = String(name.dropLast(5)) + "…" }
        let x = body.minX + 84.5
        TextDraw.line(name, font: nameFont, color: fg, x: x, baseline: body.minY + 43, in: ctx)
        var sub = Strings.fileKind(a) + " \u{00B7} " + Format.bytes(a.byteSize)
        if case let .uploading(pr) = a.transfer {
            sub = Format.bytes(Int(Double(a.byteSize) * pr)) + " / " + Format.bytes(a.byteSize)
            let bar = CGRect(x: x, y: body.minY + 64, width: body.width - 100, height: 4)
            fg.withAlphaComponent(0.3).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: 2).fill()
            fg.setFill()
            UIBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(pr), height: 4), cornerRadius: 2).fill()
        }
        TextDraw.line(sub, font: .systemFont(ofSize: 11), color: fg.withAlphaComponent(0.6), x: x, baseline: body.minY + 58.5, in: ctx)
    }

    /// The round save button beside a photo or video (measured: 28 pt, 14 pt
    /// from the media, vertically centred).
    static let saveButtonOffset: CGFloat = 14
    static func drawSaveButton(_ ctx: CGContext, body: CGRect, outgoing: Bool) {
        let d: CGFloat = 28
        let x = outgoing ? body.minX - saveButtonOffset - d : body.maxX + saveButtonOffset
        let r = CGRect(x: x, y: body.midY - d / 2, width: d, height: d)
        Fixture.badge.setFill()
        UIBezierPath(ovalIn: r).fill()
        let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let g = UIImage(systemName: "square.and.arrow.down", withConfiguration: cfg)?.withTintColor(UIColor(white: 0.66, alpha: 1), renderingMode: .alwaysOriginal) {
            let s = g.size
            g.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2 - 0.5, width: s.width, height: s.height))
        }
    }

    /// Thread preview (measured, macOS 26): an outlined bubble with the root's
    /// thumbnail, title and site; or, for a photo, a small thumbnail bubble.
    /// Then a 2.5 pt stub at x 33.75 and "N Replies" (2 or more replies).
    static func drawThreadPreview(_ ctx: CGContext, _ pv: ThreadPreview, top: CGFloat, width: CGFloat) {
        let left = Fixture.leftEdge
        let box = CGRect(x: left, y: top, width: pv.box.width, height: pv.box.height)
        if pv.isThumbnail, case let .attachment(a) = pv.part {
            ctx.saveGState()
            BubblePath.make(body: box, outgoing: false, tail: true).addClip()
            Fixture.incoming.setFill()
            ctx.fill(box.insetBy(dx: -10, dy: -10))
            if let ref = a.kind == "video" ? (a.poster ?? a.asset) : a.asset, let img = Images.load(ref) {
                let s = max(box.width / img.size.width, box.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                // The tail shows the image too: draw it a little past the body.
                img.draw(in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h + 6))
            }
            ctx.restoreGState()
        } else if pv.isText {
            let path = BubblePath.make(body: box.insetBy(dx: 0.5, dy: 0.75), outgoing: false, tail: true)
            path.lineWidth = 1
            PreviewStyle.stroke.setStroke()
            path.stroke()
            TextDraw.line(pv.textLine, font: ThreadPreview.textFont, color: PreviewStyle.textGray, x: box.minX + 8, baseline: box.minY + 16.5, in: ctx)
        } else {
            let path = BubblePath.make(body: box.insetBy(dx: 0.5, dy: 0.75), outgoing: false, tail: true)
            path.lineWidth = 1
            PreviewStyle.stroke.setStroke()
            path.stroke()
            let thumb = CGRect(x: box.minX + 6.5, y: box.minY + 10.5, width: 26, height: 26)
            ctx.saveGState()
            UIBezierPath(roundedRect: thumb, cornerRadius: 6).addClip()
            UIColor(white: 0.56, alpha: 1).setFill()
            ctx.fill(thumb)
            if case let .link(_, _, _, image?, _) = pv.part, let img = Images.load(image) {
                let s = max(thumb.width / img.size.width, thumb.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                img.draw(in: CGRect(x: thumb.midX - w / 2, y: thumb.midY - h / 2, width: w, height: h))
            }
            ctx.restoreGState()
            let (title, sub) = pv.lines
            TextDraw.line(title, font: ThreadPreview.titleFont, color: PreviewStyle.title, x: box.minX + 39, baseline: box.minY + 21, in: ctx)
            TextDraw.line(sub, font: ThreadPreview.subFont, color: PreviewStyle.subtitle, x: box.minX + 39, baseline: box.minY + 34, in: ctx)
        }
        let stubTop = box.maxY + pv.stubGap
        let stubH = pv.stubHeight
        Fixture.connector.setFill()
        UIBezierPath(roundedRect: CGRect(x: 32.5, y: stubTop, width: 2.5, height: stubH), cornerRadius: 1.25).fill()
        if pv.count >= 2 {
            let f = UIFont.systemFont(ofSize: 10, weight: .semibold)
            TextDraw.line(Strings.replies(pv.count), font: f, color: PreviewStyle.repliesBlue, x: 44.5, baseline: box.maxY + (pv.isText ? 12.5 : 11.5), in: ctx,
                          kern: RowDraw.captionKern)
        }
    }

    private static func fillBubble(_ ctx: CGContext, _ shape: UIBezierPath, outgoing: Bool, windowY: CGFloat) {
        if outgoing {
            if windowY.isNaN { return }     // filled by the row's gradient layer
            ctx.saveGState()
            shape.addClip()
            ctx.drawLinearGradient(Fixture.outgoingGradient, start: CGPoint(x: 0, y: -windowY), end: CGPoint(x: 0, y: Fixture.gradientHeight - windowY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        } else {
            Fixture.incoming.setFill()
            shape.fill()
        }
    }

    /// Map snapshot with its caption inside (measured: 12 pt white at x 13,
    /// baseline 14 pt above the image bottom). The image is `mapOverhang`
    /// taller than the layout slot.
    static func drawMapSnapshot(_ ctx: CGContext, _ img: UIImage, body: CGRect, caption: String, tail: Bool, outgoing: Bool) {
        let full = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height + Images.mapOverhang)
        ctx.saveGState()
        BubblePath.make(body: full, outgoing: outgoing, tail: tail).addClip()
        img.draw(in: full)
        ctx.restoreGState()
        TextDraw.line(caption, font: .systemFont(ofSize: 12), color: .white, x: full.minX + 13, baseline: full.maxY - 14, in: ctx)
    }

    static func drawLocation(_ ctx: CGContext, body: CGRect, title: String, subtitle: String, tail: Bool, outgoing: Bool) {
        let shape = BubblePath.make(body: body, outgoing: outgoing, tail: tail)
        ctx.saveGState()
        Fixture.incoming.setFill()
        shape.fill()
        shape.addClip()
        // Map-like tile: blocks, parks and streets in dark map colours.
        let map = CGRect(x: body.minX, y: body.minY, width: body.width, height: 150)
        UIColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1).setFill()
        ctx.fill(map)
        UIColor(red: 0.16, green: 0.24, blue: 0.18, alpha: 1).setFill()
        ctx.fill(CGRect(x: map.minX + 150, y: map.minY + 12, width: 70, height: 46))
        UIColor(red: 0.13, green: 0.2, blue: 0.3, alpha: 1).setFill()
        ctx.fill(CGRect(x: map.minX, y: map.minY + 112, width: 90, height: 38))
        ctx.saveGState()
        ctx.translateBy(x: map.midX, y: map.midY)
        ctx.rotate(by: -0.35)
        UIColor(white: 0.32, alpha: 1).setStroke()
        for i in -6...6 {
            ctx.setLineWidth(i % 3 == 0 ? 4 : 1.5)
            ctx.move(to: CGPoint(x: CGFloat(i) * 26, y: -140)); ctx.addLine(to: CGPoint(x: CGFloat(i) * 26, y: 140))
            ctx.move(to: CGPoint(x: -180, y: CGFloat(i) * 22)); ctx.addLine(to: CGPoint(x: 180, y: CGFloat(i) * 22))
            ctx.strokePath()
        }
        ctx.restoreGState()
        // Pin.
        let pin = CGPoint(x: map.midX, y: map.midY)
        UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: pin.x - 11, y: pin.y - 22, width: 22, height: 22)).fill()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: pin.x - 4, y: pin.y - 15, width: 8, height: 8)).fill()
        UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: pin.x - 2, y: pin.y - 2, width: 4, height: 4)).fill()
        ctx.restoreGState()
        TextDraw.line(title, font: Sizing.linkTitleFont, color: UIColor(white: 0.93, alpha: 1), x: body.minX + 10, baseline: map.maxY + 18, in: ctx)
        TextDraw.line(subtitle, font: .systemFont(ofSize: 10), color: UIColor(white: 0.68, alpha: 1), x: body.minX + 10, baseline: map.maxY + 32, in: ctx)
    }

    /// Tapback badges on the part's top corner (outer side), stacked, all grey (macOS 27).
    /// Tapback badges (measured on macOS 26 Messages, 2x screenshot): a 27.5 pt
    /// disc whose center is 2 pt inside the bubble's top outer corner and
    /// 8.25 pt above its top edge, colour (59, 59, 61), the tapback as a colour
    /// emoji, and two tail circles (8 pt and 4 pt) toward the outside. Mine is
    /// blue. Further badges stack 12 pt toward the bubble's middle.
    static func drawReactions(_ ctx: CGContext, _ rs: [Reaction], body: CGRect, outgoing: Bool) {
        // Outgoing bubbles carry the badge on their left (top-left), incoming on their right.
        let side: CGFloat = outgoing ? -1 : 1
        for (i, r) in rs.enumerated().reversed() {
            let d: CGFloat = 27.5
            let cx = (outgoing ? body.minX + 2 : body.maxX - 2) - side * CGFloat(i) * 12
            let c = CGPoint(x: cx, y: body.minY - 8.25)
            // macOS 27: my tapback badge is grey too (lossless still, (59, 59, 61)).
            let fill = Fixture.badge
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 1.5, color: UIColor(white: 0, alpha: 0.35).cgColor)
            fill.setFill()
            if i == 0 {
                UIBezierPath(ovalIn: CGRect(x: c.x + side * 8.5 - 4, y: c.y + 13.25 - 4, width: 8, height: 8)).fill()
                UIBezierPath(ovalIn: CGRect(x: c.x + side * 14.25 - 2, y: c.y + 19.25 - 2, width: 4, height: 4)).fill()
            }
            UIBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
            ctx.restoreGState()
            let rect = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            switch r.kind {
            case let .emoji(e):
                drawEmoji(e, in: rect, ctx: ctx)
            case let .tapback(t):
                if let e = TapbackGlyph.emoji(t) { drawEmoji(e, in: rect, ctx: ctx) }
                else { TapbackGlyph.draw(t, in: rect.insetBy(dx: 7, dy: 7), color: .white, ctx: ctx) }
            }
        }
    }

    static func drawEmoji(_ e: String, in rect: CGRect, ctx: CGContext) {
        let f = UIFont.systemFont(ofSize: 15)
        let w = TextDraw.width(e, font: f)
        TextDraw.line(e, font: f, color: .white, x: rect.midX - w / 2, baseline: rect.midY + 5.5, in: ctx)
    }
}

enum TapbackGlyph {
    /// macOS 26 draws tapbacks as colour emoji (laugh keeps the "HA HA" glyph).
    static func emoji(_ t: String) -> String? {
        switch t {
        case "love": return "\u{2764}\u{FE0F}"
        case "like": return "\u{1F44D}"
        case "dislike": return "\u{1F44E}"
        case "emphasize": return "\u{203C}\u{FE0F}"
        case "question": return "\u{2753}"
        default: return nil
        }
    }
    static let all = ["love", "like", "dislike", "laugh", "emphasize", "question"]
    static func draw(_ t: String, in r: CGRect, color: UIColor, ctx: CGContext) {
        let symbol: String?
        switch t {
        case "love": symbol = "heart.fill"
        case "like": symbol = "hand.thumbsup.fill"
        case "dislike": symbol = "hand.thumbsdown.fill"
        case "emphasize": symbol = "exclamationmark.2"
        case "question": symbol = "questionmark"
        default: symbol = nil
        }
        if let symbol, let img = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: r.height * 0.8, weight: .bold))?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            let s = img.size
            img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        } else {
            let f = UIFont.systemFont(ofSize: r.height * 0.42, weight: .heavy)
            let lines = Strings.laughGlyph.components(separatedBy: "\n")
            for (i, l) in lines.enumerated() {
                TextDraw.line(l, font: f, color: color, x: r.midX - TextDraw.width(l, font: f) / 2,
                              baseline: r.midY - 1 + CGFloat(i) * r.height * 0.42, in: ctx)
            }
        }
    }
}

/// Off-main rendering of static rows into bitmaps, with a bounded cache.
final class RowBitmaps {
    static let shared = RowBitmaps()
    private var cache: [RowSpec: CGImage] = [:]
    private var order: [RowSpec] = []
    private var waiters: [RowSpec: [(CGImage) -> Void]] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()
    static let capacity = 500
    /// Row bitmaps in bytes (media-heavy histories: a 300 x 360 pt photo row is 1.7 MB at 2x).
    static let byteBudget = 160 << 20
    private(set) var bytes = 0

    func image(for spec: RowSpec) -> CGImage? { cache[spec] }
    func has(_ spec: RowSpec) -> Bool { TiledBubble.applies(spec) || cache[spec] != nil || waiters[spec] != nil }

    /// Main thread: get the bitmap now or when it is rendered.
    func request(_ spec: RowSpec, _ done: ((CGImage) -> Void)? = nil) {
        // Long text rows are tiles (TiledBubble.swift): no bitmap, and no spec (with its text) held here.
        if TiledBubble.applies(spec) { done?(TiledBubble.emptyImage); return }
        if let img = cache[spec] { done?(img); return }
        if waiters[spec] != nil { if let done { waiters[spec]!.append(done) }; return }
        waiters[spec] = done.map { [$0] } ?? []
        let gen = Fixture.paletteGeneration
        // Newest first: older pending renders drop a priority step (a fling's rows that left
        // the screen render after the rows now on it).
        for op in queue.operations where !op.isExecuting {
            switch op.queuePriority { case .veryHigh: op.queuePriority = .high; case .high: op.queuePriority = .normal
            case .normal: op.queuePriority = .low; default: op.queuePriority = .veryLow }
        }
        enqueue(spec, gen, prefetch: done == nil)
    }

    private func enqueue(_ spec: RowSpec, _ gen: Int, prefetch: Bool) {
        let asked = CACurrentMediaTime()
        let op = BlockOperation {
            // Rows that left the screen before their turn are not drawn (no decode, no
            // idle backlog after a fling): a cell still waits for it, or it is a fresh prefetch.
            guard self.isWanted(spec) || (prefetch && CACurrentMediaTime() - asked < 0.5) else {
                DispatchQueue.main.async {
                    RowBitmaps.skipped += 1
                    // A cell may have asked again meanwhile: render for it, else forget the waiters.
                    if self.isWanted(spec), self.waiters[spec] != nil { self.enqueue(spec, gen, prefetch: false) }
                    else { self.waiters[spec] = nil }
                }
                return
            }
            let img = RowBitmaps.render(spec)
            self.deliver(spec, img, gen)
        }
        op.queuePriority = .veryHigh
        queue.addOperation(op)
    }

    /// Rows that visible cells wait for (any thread reads; main writes).
    private let demandLock = NSLock()
    private var demand: [RowSpec: Int] = [:]
    static var skipped = 0
    func want(_ s: RowSpec) { demandLock.lock(); demand[s, default: 0] += 1; demandLock.unlock() }
    func unwant(_ s: RowSpec) {
        demandLock.lock()
        if let n = demand[s] { demand[s] = n > 1 ? n - 1 : nil }
        demandLock.unlock()
    }
    func isWanted(_ s: RowSpec) -> Bool { demandLock.lock(); defer { demandLock.unlock() }; return demand[s] != nil }

    /// Finished bitmaps reach the main thread in batches: one main-queue
    /// block applies everything rendered since the last one.
    private let pendingLock = NSLock()
    private var pending: [(RowSpec, CGImage, Int)] = []
    private func deliver(_ spec: RowSpec, _ img: CGImage, _ gen: Int) {
        pendingLock.lock()
        let first = pending.isEmpty
        pending.append((spec, img, gen))
        pendingLock.unlock()
        guard first else { return }
        DispatchQueue.main.async {
            self.pendingLock.lock()
            let batch = self.pending
            self.pending = []
            self.pendingLock.unlock()
            for (spec, img, gen) in batch {
                // Rendered with an older palette: drop it and render again.
                guard gen == Fixture.paletteGeneration else {
                    let w = self.waiters.removeValue(forKey: spec) ?? []
                    for d in w { self.request(spec, d) }
                    if w.isEmpty { self.request(spec) }
                    continue
                }
                self.store(spec, img)
                self.waiters.removeValue(forKey: spec)?.forEach { $0(img) }
            }
        }
    }

    private func store(_ spec: RowSpec, _ img: CGImage) {
        if TiledBubble.applies(spec) { return }
        if let old = cache[spec] { bytes -= old.bytesPerRow * old.height } else { order.append(spec) }
        cache[spec] = img
        bytes += img.bytesPerRow * img.height
        // Trim in chunks (removing from the front of the order array on every
        // insert copied it each time). Bounded by rows and by bytes (media rows are large).
        if order.count > RowBitmaps.capacity + 100 || bytes > RowBitmaps.byteBudget {
            var n = max(0, order.count - RowBitmaps.capacity), freed = 0
            if bytes > RowBitmaps.byteBudget {
                while n < order.count, bytes - freed > RowBitmaps.byteBudget * 4 / 5 {
                    freed += cache[order[n]].map { $0.bytesPerRow * $0.height } ?? 0
                    n += 1
                }
            }
            let drop = order.prefix(n)
            let imgs = drop.compactMap { cache.removeValue(forKey: $0) }
            bytes -= imgs.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            // Freed off the main thread (vm_deallocate blocked main for up to 291 ms).
            Reclaimer.release(imgs)
            order.removeFirst(drop.count)
        }
    }
    var count: Int { cache.count }

    /// Palette change: every cached bitmap is stale (freed off main).
    func removeAll() {
        Reclaimer.release(Array(cache.values))
        bytes = 0
        cache.removeAll()
        order.removeAll()
    }

    /// Bitmaps rendered ahead of time (loader queue), inserted on main.
    func insert(_ items: [(RowSpec, CGImage)]) { items.forEach { store($0.0, $0.1) } }

    /// Render the rows that will be on screen first (loader queue).
    static func prerender(_ specs: ArraySlice<RowSpec>) -> [(RowSpec, CGImage)] {
        specs.compactMap { spec in
            switch spec.kind { case .receipt, .typing: return nil; default: return (spec, render(spec)) }
        }
    }

    static func render(_ spec: RowSpec) -> CGImage {
        if TiledBubble.applies(spec) { return TiledBubble.emptyImage }
        let span = RowDraw.drawSpan(spec)
        let size = CGSize(width: span.upperBound - span.lowerBound, height: spec.height + 2 * RowDraw.margin)
        return WideBitmap.make(size: size, scale: Fixture.renderScale, opaque: false) { ctx in
            ctx.translateBy(x: -span.lowerBound, y: 0)
            RowDraw.drawStatic(spec, ctx, windowY: .nan)
        }
    }
}

/// An 8-bit Display P3 bitmap with a y-down UIKit drawing context. The palette is
/// Display P3 (README: Colour); an sRGB bitmap clips the P3 colours outside sRGB
/// (the replies blue, the outgoing blues in the header backdrop). Same 4 bytes per
/// pixel as the sRGB `.standard` renderer it replaces. AppKit builds draw through the
/// shim's renderer, whose bitmaps are in the window's colour space already.
enum WideBitmap {
    static let space = CGColorSpace(name: CGColorSpace.displayP3)!
    static func make(size: CGSize, scale: CGFloat, opaque: Bool, _ draw: (CGContext) -> Void) -> CGImage {
        #if canImport(UIKit)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = opaque
        fmt.preferredRange = .extended
        return UIGraphicsImageRenderer(size: size, format: fmt).image { draw($0.cgContext) }.cgImage!
        #else
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: fmt).image { draw($0.cgContext) }.cgImage!
        #endif
    }
}

/// Releases large buffers (row bitmaps) on a background queue. Freeing a
/// bitmap calls vm_deallocate; under machine load that call blocked the main
/// thread for up to 291 ms in a profile. The hop through the main queue lets
/// Core Animation drop its references in the current turn first, so the
/// background block holds the last one.
enum Reclaimer {
    private static let queue = DispatchQueue(label: "messages.reclaim", qos: .utility)
    static func release(_ object: Any?) {
        guard let object else { return }
        DispatchQueue.main.async { queue.async { withExtendedLifetime(object) {} } }
    }
}

/// Message bubble fill (outgoing bubbles shade with window position).
enum BubbleView {
    static func drawBubble(_ ctx: CGContext, body: CGRect, lines: [String], outgoing: Bool, tail: Bool, windowY: CGFloat = 0) {
        let shape = BubblePath.make(body: body, outgoing: outgoing, tail: tail)
        if outgoing {
            if windowY.isNaN { return }     // filled by the row's gradient layer
            ctx.saveGState()
            shape.addClip()
            ctx.drawLinearGradient(Fixture.outgoingGradient, start: CGPoint(x: 0, y: -windowY),
                                   end: CGPoint(x: 0, y: Fixture.gradientHeight - windowY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        } else {
            Fixture.incoming.setFill()
            shape.fill()
        }
    }
}

/// Thread preview colours, measured in an inactive macOS 26 window (outline
/// 80, title 143, site 86, "N Replies" blue). Here, not in `Fixture`, because
/// ios/ compiles this file with its own `Fixture`.
enum PreviewStyle {
    static let stroke = UIColor(white: 80 / 255, alpha: 1)
    static let title = UIColor(white: 143 / 255, alpha: 1)
    static let subtitle = UIColor(white: 86 / 255, alpha: 1)
    /// "N Replies" (thread previews and reply labels), Display P3 (screencapture -l).
    static let repliesBlue = Fixture.p3(63, 143, 247)
    /// A text root's line (screencapture -l, macOS 27: glyph core 129).
    static let textGray = UIColor(white: 129 / 255, alpha: 1)
}
