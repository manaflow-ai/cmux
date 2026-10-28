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
        // Fonts held for the process (HomeFonts, cx-qpqs); receipts draw on RowBitmaps' threads.
        [(bold, HomeFonts.system(ofSize: Fixture.captionSize, weight: .semibold), Fixture.secondaryText),
         (rest, HomeFonts.system(ofSize: Fixture.captionSize), Fixture.secondaryText)]
    }
    static let captionKern: CGFloat = -0.03

    /// Horizontal span that needs pixels (cell bitmaps stay small).
    static func drawSpan(_ spec: RowSpec) -> ClosedRange<CGFloat> {
        if case .typing = spec.kind { return 0...min(spec.width, 140) }
        if case .receipt = spec.kind { return max(0, spec.metrics.receiptRight - 170)...spec.width }
        guard case let .part(p) = spec.kind else { return 0...spec.width }
        let x = p.cmuxBodyX(rightEdge: spec.metrics.rightEdge) // cmux: a group's incoming bubbles sit right of the avatar column
        // Media carry a save button 14 + 28 pt beside them.
        var media = false
        if case let .attachment(a) = p.part, a.kind == "image" || a.kind == "video" { media = true }
        let extra: CGFloat = media ? 46 : 0
        // cmux: the span starts at the avatar column when the row draws an avatar.
        let lower = min(x - 36 - (p.outgoing ? extra : 0), p.cmuxAvatar == nil ? .infinity : SenderAvatar.left - 1)
        return max(0, lower)...min(spec.width, x + p.size.width + 20 + (p.outgoing ? 0 : extra))
    }

    /// Whether a row's bitmap is the same at every row width: its drawn span is the same size at
    /// every width and the row is drawn at the same place relative to the span's start (render
    /// translates by it), so the bubble, its tail, badges and save button (or the receipt's text)
    /// have the same pixels. Custom rows draw through providers and long text through tiles: never.
    /// - An outgoing bubble moves with the right edge: its span must not be cut by the row's edges.
    /// - An incoming bubble stays at the left edge: its span starts at 0 at every width (the
    ///   36 pt margin left of the bubble is cut there the same way), so only the right edge must
    ///   not cut it. (Before, the left cut made every incoming row width-dependent: in a divider
    ///   drag on the idle mini, macOS 26, 639 of 1969 rows the width passes drew again were
    ///   incoming bubbles of the same size, same pixels.)
    /// - A receipt is drawn right-aligned at `receiptRight`, which moves with the width, in the
    ///   span from 170 pt left of it to the row's right edge (235 more rows in that drag).
    /// `--row-width-keys` or MLAB_EXP=rowwidthkeys: only outgoing bubbles that no edge cuts (the
    /// rule before; the A/B control).
    static func widthInvariant(_ spec: RowSpec) -> Bool {
        if case .receipt = spec.kind { return fixedSpanKeys && spec.metrics.receiptRight - 170 >= 0 }
        guard case let .part(p) = spec.kind else { return false }
        if case .custom = p.part { return false }
        let x = p.cmuxBodyX(rightEdge: spec.metrics.rightEdge) // cmux: group indent
        var media = false
        if case let .attachment(a) = p.part, a.kind == "image" || a.kind == "video" { media = true }
        let extra: CGFloat = media ? 46 : 0
        let rightFits = x + p.size.width + 20 + (p.outgoing ? 0 : extra) <= spec.width
        if !p.outgoing, fixedSpanKeys { return rightFits }
        return x - 36 - (p.outgoing ? extra : 0) >= 0 && rightFits
    }
    /// Whether row `b` draws exactly the pixels of row `a`'s bitmap, counted from each one's span start
    /// (`drawSpan`), with nothing but transparent columns past the narrower span's end: a live resize keeps
    /// `a`'s bitmap for `b` (RowCell.configure, cx-3cb resize-drops2). The same row at another width, and:
    /// - an outgoing plain text bubble (its fill is the cell's gradient layer, its bitmap only the text, drawn
    ///   at the body's left plus the padding) whose lines and everything but the bubble width are the same and
    ///   whose span no row edge cuts at either width (a wrapped line's trailing space clamps the bubble to the
    ///   column, so the bubble narrows with the window while its lines stay);
    /// - an incoming "N Replies" or label row, or an incoming thread preview: drawn at fixed x from the left
    ///   edge in a span from 0 to the row width.
    static func samePixels(_ a: RowSpec, _ b: RowSpec) -> Bool {
        guard a.key == b.key, a.height == b.height else { return false }
        switch (a.kind, b.kind) {
        case let (.part(p), .part(q)):
            guard p.outgoing, q.outgoing, case .text = p.part, p.markdown == nil, q.markdown == nil,
                  !TiledBubble.applies(a), !TiledBubble.applies(b) else { return false }
            var r = q
            r.size.width = p.size.width
            guard r == p else { return false }
            func uncut(_ s: RowSpec, _ w: CGFloat) -> Bool {
                let x = s.metrics.rightEdge - w
                return x - 36 >= 0 && x + w + 20 <= s.width
            }
            return uncut(a, p.size.width) && uncut(b, q.size.width)
        case let (.replies(n, root, o), .replies(m, root2, o2)):
            return !o && !o2 && n == m && root == root2
        case let (.label(t, o, c), .label(t2, o2, c2)):
            return !o && !o2 && t == t2 && c == c2
        case let (.threadPreview(x), .threadPreview(y)):
            return !x.outgoing && x == y
        default:
            return false
        }
    }

    static let fixedSpanKeys: Bool = {
        let exp = (ProcessInfo.processInfo.environment["MLAB_EXP"] ?? "").split(separator: ",")
        return !(CommandLine.arguments.contains("--row-width-keys") || exp.contains("rowwidthkeys"))
    }()

    /// Body rect of a part row in row coordinates (window width, margin above).
    static func bodyRect(_ spec: RowSpec) -> CGRect {
        guard case let .part(p) = spec.kind else { return .zero }
        let x = p.cmuxBodyX(rightEdge: spec.metrics.rightEdge) // cmux: group indent
        return CGRect(x: x, y: margin, width: p.size.width, height: p.bodySize.height)
    }

    /// The drawn outline (body and tail) of a part in its body frame `body`. Only an outgoing text
    /// balloon differs from its frame: real Messages (macOS 27) draws it a little inside the frame, in
    /// width and height alike, while the row and the row pitch keep the frame's 16 n + 14 pt
    /// (tools/evidence/ANIMATIONS.md section 1 "Multi-line sends", tools/evidence/anim/refs3line/bubheight.py;
    /// references/real-messages/interactions/send-3line, send-4line, send-2line-break and
    /// deactivate-activate/tp1200ms.png, summed coverage on flat columns and rows):
    /// - 2 lines and more (15 bubbles): the top and left edges 0.04 pt outside the frame (0.08 device
    ///   px: edge fraction .92), the bottom and right edges 0.42 pt inside it (fraction .16), so the
    ///   balloon is 0.38 pt smaller: 45.62 / 61.62 / 77.62 pt in 46 / 62 / 78 pt rows (h = 15.998 n +
    ///   13.621, rms 0.005). The right edge of every multi-line balloon in deactivate-activate is 0.42 pt
    ///   left of the 608 pt edge, and its three balloon widths there are whole device px minus 0.38 pt (742.24,
    ///   724.24, 694.24 px where our frames are 742.17, 724.70, 694.21 px wide): the frame's left edge is on the
    ///   device pixel at or left of ours (left edges 472.92, 490.92, 520.92 px for our 473.83, 491.30, 521.79).
    /// - 1 line (4 bubbles in the send-1line takes, 7 in deactivate-activate): top 0.023 pt outside (fraction .954), bottom 0.106 pt inside (.788): 29.917 pt.
    /// - The body keeps its frame's corners (BubblePath.make cornersOf); a 1-line balloon ends in half circles of its own
    ///   height (circularEnds).
    /// - The tail stays at the balloon's bottom right corner (Messages' tail tip moves with it, 1 px up
    ///   and left in deactivate-activate).
    /// No cause in our geometry explains it (the mask, tail and text layout all place the frame exactly);
    /// the same offsets on all four sides of balloons of every width point to Messages' balloon artwork
    /// being drawn inset in its frame. Messages' edges are also softer (two partly covered device px per
    /// edge, coverage .21/.87 at the top and .93/.24 at the bottom); ours stay one-pixel crisp edges.
    /// Incoming balloons are exactly their frames (30 / 46 pt; a 1-line one ends in half circles: circularEnds);
    /// media, links and custom rows keep theirs.
    /// macOS 27 only: the macOS 26 fits (MESSAGESLAB_OS_FIT=26) keep the frame. The only macOS 26 reference, the
    /// original recording (HEVC 4:2:0), has no still multi-line outgoing balloon, and with the inset its flying
    /// bubble's bottom edge error got worse (motion-gate capture26 parity: edge_B_rms 1.36 -> 1.67 px).
    static func balloon(_ body: CGRect, row p: PartRow, scale: CGFloat = Fixture.renderScale) -> CGRect {
        insetApplies(p) ? insetBalloon(body, scale: scale) : body
    }

    /// An outgoing text part on macOS 27 (Catalyst / AppKit): its balloon is drawn inside its frame (`balloon`) and its
    /// cell masks the fill with Messages' soft edge (SoftBalloon).
    static func insetApplies(_ p: PartRow) -> Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        return false
#else
        guard p.outgoing, case .text = p.part, !ComposeMetrics.macOS26 else { return false }
        return true
#endif
    }

    /// `balloon`'s measured rule without the part check.
    static func insetBalloon(_ body: CGRect, scale: CGFloat = Fixture.renderScale) -> CGRect {
        let s = scale
        let multi = body.height > 38 // 30 pt for 1 line, 46 for 2
        let out: CGFloat = multi ? 0.04 : 0.023, inset: CGFloat = multi ? 0.419 : 0.106
        let left = floor(body.minX * s + 0.001) / s
        return CGRect(x: left - out, y: body.minY - out,
                      width: body.maxX - inset - (left - out), height: body.height + out - inset)
    }

    /// Whether the part's balloon ends in exact half circles (BubblePath.make circularEnds): a 1-line plain text
    /// balloon (30 pt frame) on macOS, incoming and outgoing (the outgoing one as its inset balloon, RowDraw.balloon,
    /// and its soft mask, SoftBalloon). Markdown balloons (a 1-line code block is 42 pt, under UIKit's 45.86 pt
    /// limit) keep UIKit's shape. The iOS app keeps UIKit's shape.
    static func circularEnds(_ p: PartRow) -> Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        return false
#else
        guard case .text = p.part, p.markdown == nil else { return false }
        return p.bodySize.height <= Fixture.lineHeight + 2 * Fixture.bubblePadY + 0.01
#endif
    }

    /// Outgoing shapes whose fill is the window-position gradient (a layer).
    static func needsFill(_ spec: RowSpec) -> Bool {
        guard case let .part(p) = spec.kind, p.outgoing else { return false }
        switch p.part {
        case .text: return true
        case let .attachment(a): return !["image", "video"].contains(a.kind) && !HomeFileCard.isCard(a) // cmux: file cards are neutral (#26395)
        case let .custom(c): return CustomRows.needsFill(c, outgoing: true)
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
                TextDraw.line(s, font: f, color: c, x: x, baseline: top + spec.height - 8, in: ctx, kern: captionKern) // 27.5 in a 35.5 pt row
                x += TextDraw.width(s, font: f, kern: captionKern)
            }
        case let .notice(s):
            // As the unsent notice below (ask 9, HostHooks.swift).
            // cmux: at the typing bubble's left edge, the row above it (Layout), not centered.
            // cmux: one row per line, each cut to the column (HomeNoticeRows; one line draws as upstream's).
            HomeNoticeRows.draw(s, x: noticeLeft, baseline: top + 12, maxWidth: m.receiptRight - noticeLeft, in: ctx)
        case let .unsent(outgoing):
            let s = outgoing ? Strings.unsentMine : Strings.unsentTheirs
            let f = HomeFonts.system(ofSize: 11) // HomeFonts (cx-qpqs)
            let w = TextDraw.width(s, font: f)
            TextDraw.line(s, font: f, color: Fixture.secondaryText, x: m.centerX + 0.1 - w / 2, baseline: top + 12, in: ctx)
        case let .label(text, outgoing, color):
            let f = HomeFonts.system(ofSize: 10, weight: .medium) // HomeFonts (cx-qpqs)
            let c: UIColor = color == .failure ? UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
                : color == .link ? Fixture.labelLink : Fixture.secondaryText // cmux: themed link tint
            let w = TextDraw.width(text, font: f)
            TextDraw.line(text, font: f, color: c, x: outgoing ? m.receiptRight - w : Fixture.labelLeft, baseline: top + 11, in: ctx)
        case let .replies(count, _, outgoing):
            let f = HomeFonts.system(ofSize: 10, weight: .semibold) // HomeFonts (cx-qpqs)
            let s = Strings.replies(count)
            let w = TextDraw.width(s, font: f, kern: captionKern)
            TextDraw.line(s, font: f, color: Fixture.repliesTint, // cmux: themed link tint
                          x: outgoing ? m.receiptRight - w : Fixture.labelLeft, baseline: top + 14, in: ctx, kern: captionKern)
        case let .part(p):
            let x = p.cmuxBodyX(rightEdge: m.rightEdge) // cmux: group indent
            let body = CGRect(x: x, y: margin, width: p.size.width, height: p.bodySize.height)
            PartRenderer.draw(ctx, row: p, body: body, windowY: windowY, highlight: highlight)
            // cmux: a group chat's sender avatar beside the last bubble of their run.
            if !p.outgoing, let avatar = p.cmuxAvatar { avatar.draw(in: ctx, rect: SenderAvatar.rect(beside: body)) }
        case let .senderName(name):
            // cmux: a group chat's sender name, at the indented incoming bubble's text edge (iMessage).
            let f = HomeFonts.system(ofSize: 11) // HomeFonts (cx-qpqs)
            TextDraw.line(name, font: f, color: Fixture.secondaryText, x: senderNameLeft, baseline: top + 11, in: ctx)
        case let .receipt(bold, rest):
            drawReceipt(ctx, bold, rest, receiptRight: m.receiptRight, top: top)
        case .typing:
            // macOS: the bubble is a vector layer of the cell (RowCell.typingBody), placed on whole device pixels;
            // this bitmap drew it at fractional geometry and was then resampled at a fractional position (each
            // straight edge spread over 2 px). The iOS app keeps it in the bitmap.
#if os(iOS) && !targetEnvironment(macCatalyst)
            drawTypingBubble(ctx, top: top + typingBubble.minY - margin)
#endif
        case let .threadPreview(pv):
            if pv.outgoing {
                PartRenderer.drawOutgoingThreadPreview(ctx, pv, top: top, rightEdge: m.rightEdge)
            } else {
                PartRenderer.drawThreadPreview(ctx, pv, top: top, width: spec.width)
            }
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

    /// The typing bubble without its dots and tail discs (layers that animate). Messages at rest, read from pixel
    /// coverage of its lossless typing stills (tools/evidence/anim/typedge.py; no model fit): 44 x 27 pt, its
    /// straight edges on whole device pixels (left 20 pt, top 46.5 pt above the field's top edge). macOS draws it
    /// as a layer whose top RowCell snaps to a whole device pixel (tools/evidence/ANIMATIONS.md section 6,
    /// cx-3cb typing-pixels; before: 20.14, 4.31, 43.69 x 27.19 from a capsule fit with a blur bias).
    static let typingBubble = CGRect(x: 20, y: margin + 4.335, width: 44, height: 27)
    /// cmux: a group chat's sender name's left edge (row coordinates): the indented incoming bubble's text.
    static var senderNameLeft: CGFloat { Fixture.leftEdge + SenderAvatar.bubbleInset + Fixture.bubblePadX }
    /// cmux: the host status line's left edge (row coordinates): the typing bubble's, a point in.
    static var noticeLeft: CGFloat { typingBubble.minX + 1 }
    /// The point the typing bubble grows from (row coordinates): Messages' fitted scale centre,
    /// 19.1 pt left of and 8.7 pt above the bubble's centre (tools/evidence/ANIMATIONS.md section 6).
    static var typingAnchor: CGPoint { CGPoint(x: typingBubble.midX - 19.07, y: typingBubble.midY - 8.71) }
    /// The bubble's two tail discs (row coordinates), large then small: layers of their own
    /// (RowCell.typingDiscs; on macOS they move apart from the bubble as it appears). Messages at rest: the
    /// large disc d 9.18 pt, its centre 24.78 pt from the left and 2.27 pt above the bubble's bottom; the
    /// small one d 4.75 pt at 19.00 pt, 3.40 pt below it (section 6, cx-3cb typing-pixels: exact-coverage
    /// circles against the bubble's pixel edges; window places within 0.04 pt of cx-3cb typing-breath's).
    static let typingDiscs = [CGRect(x: 24.78 - 4.59, y: typingBubble.maxY - 2.27 - 4.59, width: 9.18, height: 9.18),
                              CGRect(x: 19.00 - 2.375, y: typingBubble.maxY + 3.40 - 2.375, width: 4.75, height: 4.75)]
    /// iOS only (its row bitmap): one palette there, so the active colours (no view state reaches a bitmap).
    static func drawTypingBubble(_ ctx: CGContext, top: CGFloat) {
        let b = CGRect(x: typingBubble.minX, y: top, width: typingBubble.width, height: typingBubble.height)
        Fixture.typingColors(inactive: false).fill.setFill()
        UIBezierPath(roundedRect: b, cornerRadius: b.height / 2).fill()
    }
    static func typingDotCenter(_ i: Int) -> CGPoint {
        let b = typingBubble
        // Messages at rest: 32.25, 41.75, 51.25 pt (12.25 pt + 9.5 i from the left edge), 0.28 pt above the
        // bubble's centre (section 6, cx-3cb typing-pixels: centroids against the bubble's pixel edges).
        return CGPoint(x: 32.25 + CGFloat(i) * 9.5, y: b.midY - 0.28)
    }
}

/// Drawing for every part type.
enum PartRenderer {
    static func draw(_ ctx: CGContext, row p: PartRow, body: CGRect, windowY: CGFloat, highlight: Bool) {
        switch p.part {
        case .text:
            let lines = p.text.map { tl in tl.lines.map { _ in "" } } ?? []
            // A copy with a window y (thread view, captures) fills my balloon through the cell's soft mask
            // (SoftBalloon.clip, cx-3cb soft-copies); without a window y the cell's gradient layer fills it.
            ctx.saveGState()
            if p.outgoing, !windowY.isNaN, SoftBalloon.clip(ctx, frame: body, row: p) {
                ctx.drawLinearGradient(Fixture.outgoingGradient, start: CGPoint(x: 0, y: -windowY),
                                       end: CGPoint(x: 0, y: Fixture.gradientHeight - windowY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                BubbleView.drawBubble(ctx, shape: BubblePath.balloon(frame: body, row: p), outgoing: p.outgoing, windowY: windowY) // cmux: shared outline
            }
            ctx.restoreGState()
            _ = lines
            if let md = p.markdown {
                // Every block, at its scroll offset (thread view, morph and menu copies of the row are
                // complete); a live cell masks the bitmap under its overlays (MarkdownOverlay).
                MarkdownDraw.draw(ctx, md, body: body, outgoing: p.outgoing, offsets: MarkdownScroll.all(md.identity))
            } else if let tl = p.text { drawText(ctx, tl, in: body, outgoing: p.outgoing) }
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
            let f = HomeFonts.system(ofSize: 10) // HomeFonts (cx-qpqs)
            TextDraw.line(host, font: f, color: Fixture.secondaryText, x: body.midX - TextDraw.width(host, font: f) / 2, baseline: c.y + 24, in: ctx)
        case let .link(_, title, site, image, theme):
            // A light appearance draws every card light; a dark one keeps the card's
            // own theme (a card with no image is dark).
            drawLink(ctx, body: body, title: title ?? "", site: site ?? "", image: image,
                     dark: !Fixture.lightAppearance && (theme == "dark" || image == nil),
                     tail: p.tail, outgoing: p.outgoing)
        case let .attachment(a):
            drawAttachment(ctx, a, body: body, row: p, windowY: windowY)
        case let .custom(c):
            CustomRows.draw(ctx, c, row: p, body: body, windowY: windowY)
        case let .location(lat, lon, title, subtitle):
            if let img = Images.mapSnapshot(lat, lon) {
                drawMapSnapshot(ctx, img, body: body, caption: title ?? "", tail: p.tail, outgoing: p.outgoing)
            } else {
                drawLocation(ctx, body: body, title: title ?? "", subtitle: subtitle ?? "", tail: p.tail, outgoing: p.outgoing)
            }
        }
        if highlight {
            UIColor(white: 1, alpha: 0.12).setFill()
            ctx.saveGState()
            // My text balloon's highlight has its soft edge (SoftBalloon.clip), as the balloon under it.
            if p.outgoing, SoftBalloon.clip(ctx, frame: body, row: p) {
                ctx.fill(ctx.boundingBoxOfClipPath)
            } else {
                BubblePath.balloon(frame: body, row: p).fill() // cmux: shared outline
            }
            ctx.restoreGState()
        }
        if p.failed {
            let c = CGPoint(x: body.minX - 14, y: body.midY)
            UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)).fill()
            let f = HomeFonts.system(ofSize: 12, weight: .bold) // HomeFonts (cx-qpqs)
            TextDraw.line("!", font: f, color: .white, x: c.x - TextDraw.width("!", font: f) / 2, baseline: c.y + 4.5, in: ctx)
        }
        drawReactions(ctx, p.reactions, mine: p.myReaction, body: body, outgoing: p.outgoing, windowY: windowY)
    }

    static func drawText(_ ctx: CGContext, _ tl: TextLayout, in body: CGRect, outgoing: Bool) {
        let color = outgoing ? Fixture.outgoingText : Fixture.incomingText
        // An outgoing link is the bubble's text colour (white; a themed host's own colour).
        let link = outgoing ? Fixture.outgoingText : Fixture.incomingLink // cmux: themed link tint
        let attr = tl.attributed(color: color, linkColor: link)
        for (i, line) in tl.lines.enumerated() where line.range.length > 0 {
            let l = CTLineCreateWithAttributedString(attr.attributedSubstring(from: line.range))
            let origin = CGPoint(x: body.minX + Fixture.bubblePadX, y: body.minY + Fixture.textBaseline + tl.lineOffset(i, hard: outgoing ? TextLayout.hardBreakAdvance : Fixture.lineHeight))
            // cmux: link chips (HomeLinkChip) under the line's text.
            HomeLinkChip.drawSpans(ctx, tl.chipSpans(line: i, attr: attr), origin: origin, tint: link, outgoing: outgoing, scale: Fixture.renderScale)
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = origin
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
        TextDraw.line(site, font: HomeFonts.system(ofSize: 10), color: siteColor, x: card.minX + 10.25, baseline: y + 2.8, in: ctx, kern: -0.03) // HomeFonts (cx-qpqs)
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
            // An undelivered photo shows only the red badge (Messages); the button sat under it.
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
            TextDraw.line(d, font: HomeFonts.monospacedDigit(ofSize: 11, weight: .regular), color: fg, x: body.maxX - 36, // HomeFonts (cx-qpqs)
                          baseline: body.midY + 4, in: ctx)
        default:
            // cmux: a file is a neutral card with its type's icon and kind (HomeFileCard, #26395).
            if HomeFileCard.isCard(a) { HomeFileCard.draw(ctx, a, shape: shape, body: body); return }
            fillBubble(ctx, shape, outgoing: p.outgoing, windowY: windowY)
            let fg: UIColor = p.outgoing ? Fixture.outgoingText : Fixture.incomingText  // cmux: themed (white by default)
            let icon = CGRect(x: body.minX + 10, y: body.minY + 10, width: 28, height: 36)
            if a.kind == "contact" {
                UIColor(white: 0.55, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: body.minX + 9, y: body.minY + 10, width: 36, height: 36)).fill()
                let initial = String(a.fileName.prefix(1)).uppercased()
                let f = HomeFonts.system(ofSize: 17, weight: .semibold) // HomeFonts (cx-qpqs)
                TextDraw.line(initial, font: f, color: .white, x: body.minX + 27 - TextDraw.width(initial, font: f) / 2,
                              baseline: body.minY + 34, in: ctx)
                let name = (a.fileName as NSString).deletingPathExtension
                TextDraw.line(name, font: HomeFonts.system(ofSize: 13, weight: .semibold), color: fg, x: body.minX + 54, baseline: body.minY + 33, in: ctx) // HomeFonts (cx-qpqs)
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
            let f = HomeFonts.system(ofSize: 7, weight: .regular) // HomeFonts (cx-qpqs)
            TextDraw.line(label, font: f, color: UIColor(white: 0.6, alpha: 1), x: icon.midX - TextDraw.width(label, font: f) / 2,
                          baseline: icon.maxY - 5, in: ctx)
        }
        let nameFont = HomeFonts.system(ofSize: 13, weight: .semibold) // HomeFonts (cx-qpqs)
        var name = a.fileName
        while TextDraw.width(name, font: nameFont) > body.width - 100, name.count > 4 { name = String(name.dropLast(5)) + "…" }
        let x = body.minX + 84.5
        TextDraw.line(name, font: nameFont, color: fg, x: x, baseline: body.minY + 43, in: ctx)
        var sub = Strings.fileKind(a) + " \u{00B7} " + Format.bytes(a.byteSize)
        if case let .uploading(pr) = a.transfer {
            sub = Format.bytes(CrashGuard.int(Double(a.byteSize) * pr)) /* no trap on a NaN progress */ + " / " + Format.bytes(a.byteSize)
            let bar = CGRect(x: x, y: body.minY + 64, width: body.width - 100, height: 4)
            fg.withAlphaComponent(0.3).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: 2).fill()
            fg.setFill()
            UIBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(pr), height: 4), cornerRadius: 2).fill()
        }
        TextDraw.line(sub, font: HomeFonts.system(ofSize: 11), color: fg.withAlphaComponent(0.6), x: x, baseline: body.minY + 58.5, in: ctx) // HomeFonts (cx-qpqs)
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

    /// cmux: thread preview: the quoted root (a copy of its bubble, `drawQuoteBubble`) at the left edge, then a 2.5 pt
    /// stub at x 33.75 and "N Replies" (2 or more replies).
    static func drawThreadPreview(_ ctx: CGContext, _ pv: ThreadPreview, top: CGFloat, width: CGFloat) {
        let box = CGRect(x: Fixture.leftEdge, y: top, width: pv.box.width, height: pv.box.height)
        drawQuoteBubble(ctx, pv, box: box)
        let stubTop = box.maxY + pv.stubGap
        let stubH = pv.stubHeight
        Fixture.connector.setFill()
        UIBezierPath(roundedRect: CGRect(x: 32.5, y: stubTop, width: 2.5, height: stubH), cornerRadius: 1.25).fill()
        if pv.count >= 2 {
            let f = HomeFonts.system(ofSize: 10, weight: .semibold) // HomeFonts (cx-qpqs)
            TextDraw.line(Strings.replies(pv.count), font: f, color: Fixture.repliesTint, x: 44.5, baseline: box.maxY + (pv.isText ? 12.5 : 11.5), in: ctx, // cmux: themed link tint
                          kern: RowDraw.captionKern)
        }
    }

    /// cmux: the preview of my own root at the right edge (the side of its root, not of the reply), with
    /// "N Replies" right-aligned at 6 pt left of the edge, baseline 13.75 pt under the quote; no stub.
    static func drawOutgoingThreadPreview(_ ctx: CGContext, _ pv: ThreadPreview, top: CGFloat, rightEdge: CGFloat) {
        let box = CGRect(x: rightEdge - pv.box.width, y: top, width: pv.box.width, height: pv.box.height)
        drawQuoteBubble(ctx, pv, box: box)
        if pv.count >= 2 {
            let f = HomeFonts.system(ofSize: 10, weight: .bold) // HomeFonts (cx-qpqs)
            let s = Strings.replies(pv.count)
            let w = TextDraw.width(s, font: f, kern: RowDraw.captionKern)
            TextDraw.line(s, font: f, color: Fixture.repliesTint, x: rightEdge - 6 - w, baseline: box.maxY + (pv.isText ? 13.75 : 12.75), in: ctx, // cmux: themed link tint
                          kern: RowDraw.captionKern)
        }
    }

    /// cmux: (2026-10-20, plans/cmux-next/reply-thread-gallery.html variant A): a quoted root is its own bubble,
    /// smaller. The same fill and text colour as the root's bubble (`Fixture.outgoing`/`outgoingText` for mine,
    /// `incoming`/`incomingText` for others; themed), the same outline as every bubble (`BubblePath.balloon` of
    /// `ThreadPreview.shapeRow`: half-circle ends on one line, the 15 pt continuous corner when taller), no tail, all drawn in one transparency layer at
    /// `ThreadPreview.quoteOpacity` so the text does not show the fill through it. Replaces the 1 pt outline with
    /// blue or gray text and a full-size tail on a 24 pt body, which did not match the quoted message.
    static func drawQuoteBubble(_ ctx: CGContext, _ pv: ThreadPreview, box: CGRect) {
        var out = pv.outgoing
        // cmux: a quoted file card keeps the card's neutral fill on either side (HomeFileCard, #26395).
        if case let .attachment(a) = pv.part, HomeFileCard.isCard(a) { out = false }
        let fill = out ? Fixture.outgoing : Fixture.incoming
        // cmux (2026-10-27, Lawrence's 5:54 PM reference): my root is an outlined blue bubble with blue text,
        // not a faded fill; the Chief's root keeps its gray fill.
        let ink = out ? Fixture.outgoing : Fixture.incomingText
        let shape = BubblePath.balloon(frame: out ? box.insetBy(dx: 0.5, dy: 0.5) : box, row: pv.shapeRow)
        ctx.saveGState()
        ctx.setAlpha(out ? 1 : ThreadPreview.quoteOpacity)
        ctx.beginTransparencyLayer(in: box.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)
        if out {
            fill.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else {
            fill.setFill()
            shape.fill()
        }
        if pv.isThumbnail, case let .attachment(a) = pv.part {
            ctx.saveGState()
            shape.addClip()
            if let ref = a.kind == "video" ? (a.poster ?? a.asset) : a.asset, let img = Images.load(ref) {
                let s = max(box.width / img.size.width, box.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                img.draw(in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
            }
            ctx.restoreGState()
        } else if pv.isText {
            let first = pv.textFirstBaseline()
            for (i, line) in pv.textLines.enumerated() {
                TextDraw.line(line, font: ThreadPreview.textFont, color: ink, x: box.minX + ThreadPreview.textPadX / 2,
                              baseline: box.minY + first + ThreadPreview.textLinePitch * CGFloat(i), in: ctx)
            }
        } else {
            let thumb = CGRect(x: box.minX + 8, y: box.minY + 11.25, width: 26, height: 26)
            ctx.saveGState()
            UIBezierPath(roundedRect: thumb, cornerRadius: 6).addClip()
            ink.withAlphaComponent(0.25).setFill()
            ctx.fill(thumb)
            if case let .link(_, _, _, image?, _) = pv.part, let img = Images.load(image) {
                let s = max(thumb.width / img.size.width, thumb.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                img.draw(in: CGRect(x: thumb.midX - w / 2, y: thumb.midY - h / 2, width: w, height: h))
            }
            ctx.restoreGState()
            let (title, sub) = pv.lines
            TextDraw.line(title, font: ThreadPreview.titleFont, color: ink, x: box.minX + 39, baseline: box.minY + 21, in: ctx)
            TextDraw.line(sub, font: ThreadPreview.subFont, color: ink.withAlphaComponent(0.7), x: box.minX + 39, baseline: box.minY + 34, in: ctx)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
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
        TextDraw.line(caption, font: HomeFonts.system(ofSize: 12), color: .white, x: full.minX + 13, baseline: full.maxY - 14, in: ctx) // HomeFonts (cx-qpqs)
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
        TextDraw.line(subtitle, font: HomeFonts.system(ofSize: 10), color: UIColor(white: 0.68, alpha: 1), x: body.minX + 10, baseline: map.maxY + 32, in: ctx) // HomeFonts (cx-qpqs)
    }

    /// Tapback badges on the part's top corner (outer side), stacked.
    /// Geometry (measured on macOS 26 Messages, 2x screenshot, unchanged on macOS 27): a 27.5 pt
    /// disc whose center is 2 pt inside the bubble's top outer corner and 8.25 pt above its top
    /// edge, and two tail circles (8 pt and 4 pt) toward the outside; further badges stack 12 pt
    /// toward the bubble's middle. Colour (macOS 27, lossless tapback-menu-heart-take1 and
    /// reply-menu-send-take1): another person's badge is grey (59, 59, 61); MINE is blue, the
    /// window-position gradient of my bubbles ((81, 151, 248) at window y 277 pt, the gradient's
    /// value there). Mine is drawn here only when `windowY` is known; in a cell's bitmap
    /// (`windowY` NaN) the cell's badge layer draws it (RowCell, a window-anchored gradient like
    /// the outgoing fill, and the badge's pop). `mine`: the index of my reaction in `rs`
    /// (PartRow.myReaction).
    static func drawReactions(_ ctx: CGContext, _ rs: [Reaction], mine myIndex: Int?, body: CGRect, outgoing: Bool, windowY: CGFloat = .nan) {
        let side: CGFloat = outgoing ? -1 : 1
        for (i, r) in rs.enumerated().reversed() {
            let mine = i == myIndex
            if mine && windowY.isNaN { continue }
            let c = badgeCenter(body: body, outgoing: outgoing, index: i)
            let shape = badgePath(center: c, side: side, tails: i == 0)
            ctx.saveGState()
            if mine {
                shape.addClip()
                ctx.drawLinearGradient(Fixture.outgoingGradient, start: CGPoint(x: 0, y: -windowY), end: CGPoint(x: 0, y: Fixture.gradientHeight - windowY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                ctx.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 1.5, color: UIColor(white: 0, alpha: 0.35).cgColor)
                Fixture.badge.setFill()
                shape.fill()
            }
            ctx.restoreGState()
            drawBadgeGlyph(r.kind, center: c, ctx: ctx)
        }
    }

    static let badgeDiameter: CGFloat = 27.5
    static func badgeCenter(body: CGRect, outgoing: Bool, index i: Int) -> CGPoint {
        let side: CGFloat = outgoing ? -1 : 1
        return CGPoint(x: (outgoing ? body.minX + 2 : body.maxX - 2) - side * CGFloat(i) * 12, y: body.minY - 8.25)
    }
    /// The disc and (first badge only) its two tail circles toward the outside.
    static func badgePath(center c: CGPoint, side: CGFloat, tails: Bool) -> UIBezierPath {
        let d = badgeDiameter
        let p = UIBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
        if tails {
            p.append(UIBezierPath(ovalIn: CGRect(x: c.x + side * 8.5 - 4, y: c.y + 13.25 - 4, width: 8, height: 8)))
            p.append(UIBezierPath(ovalIn: CGRect(x: c.x + side * 14.25 - 2, y: c.y + 19.25 - 2, width: 4, height: 4)))
        }
        return p
    }
    static func drawBadgeGlyph(_ kind: Reaction.Kind, center c: CGPoint, ctx: CGContext) {
        let d = badgeDiameter
        let rect = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        switch kind {
        case let .emoji(e):
            drawEmoji(e, in: rect, ctx: ctx)
        case .tapback("love"):
            TapbackGlyph.drawLoveHeart(center: c, ctx: ctx)
        case let .tapback(t):
            if let e = TapbackGlyph.emoji(t) { drawEmoji(e, in: rect, ctx: ctx) }
            else { TapbackGlyph.draw(t, in: rect.insetBy(dx: 7, dy: 7), color: .white, ctx: ctx) }
        }
    }

    /// `scale` sizes the 15 pt emoji about the rect's center (the context menu palette: 0.89).
    static func drawEmoji(_ e: String, in rect: CGRect, ctx: CGContext, scale: CGFloat = 1) {
        let f = HomeFonts.system(ofSize: 15 * scale) // HomeFonts (cx-qpqs)
        let w = TextDraw.width(e, font: f)
        TextDraw.line(e, font: f, color: .white, x: rect.midX - w / 2, baseline: rect.midY + 5.5 * scale, in: ctx)
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
    /// The Love tapback on macOS 27 (lossless send-typed-media take, 2026-10-05): not the red
    /// emoji but a pink heart, heart.fill at 15 pt regular (4 % area error), its centroid 0.27 pt
    /// above the badge center (box middle 1.25 pt below it on the settled hearts of
    /// tapback-menu-heart-take1 and send-typed-take1; the earlier 1.52 drew it 1.25 pt high), with an elliptical radial gradient (rms 4.8 levels): center 0.34 pt
    /// right of and 8 pt above the heart's centroid, x scaled by 1.39, radius 13.85 pt; stops
    /// (238, 147, 181) at 0, (244, 189, 217) at 0.5, (235, 96, 160) at 1 (light band over the
    /// middle, deeper pink at the lobes' tops and the tip).
    static func drawLoveHeart(center c: CGPoint, ctx: CGContext) {
        guard let img = UIImage(systemName: "heart.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
        let s = img.size
        // The glyph's centroid sits 0.48 pt left of and 0.84 pt above its 19 x 17 pt box's center.
        let centroid = CGPoint(x: c.x, y: c.y - 0.27)
        let box = CGRect(x: centroid.x + 0.48 - s.width / 2, y: centroid.y + 0.84 - s.height / 2, width: s.width, height: s.height)
        let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat) in UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1).cgColor }
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [rgb(237.87, 147.07, 180.7), rgb(244.11, 188.55, 217.27), rgb(235.21, 96.07, 160.02)] as CFArray,
                                 locations: [0, 0.5, 1]) else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        img.draw(in: box)
        ctx.setBlendMode(.sourceIn)
        ctx.translateBy(x: centroid.x + 0.34, y: centroid.y - 8)
        ctx.scaleBy(x: 1 / 1.39, y: 1)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 13.85,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
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
            let f = HomeFonts.system(ofSize: r.height * 0.42, weight: .heavy) // HomeFonts (cx-qpqs)
            let lines = Strings.laughGlyph.components(separatedBy: "\n")
            for (i, l) in lines.enumerated() {
                TextDraw.line(l, font: f, color: color, x: r.midX - TextDraw.width(l, font: f) / 2,
                              baseline: r.midY - 1 + CGFloat(i) * r.height * 0.42, in: ctx)
            }
        }
    }
}

/// Off-main rendering of static rows into bitmaps, with a bounded cache. One cache for every window view: a bitmap is
/// keyed by its row and the scale it is drawn at (`Key`), so two views at two backing scales (cmux Home: windows on a
/// 2x and a 1x display) share the cache and never show each other's bitmaps. Every call takes the caller's scale
/// (default `Fixture.renderScale`: inside a view's `Fixture.withRenderScale`, the view's).
final class RowBitmaps {
    static let shared = RowBitmaps()
    /// `space`: the colour space the bitmap is drawn in (WideBitmap.drawSpace; AppKit: the window's display space,
    /// process-wide). Bitmaps of another display stay cached for a move back (cx-3cb scale-redraw).
    struct Key: Hashable { var spec: RowSpec; var scale: CGFloat; var space: CGColorSpace? = WideBitmap.drawSpace }
    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var waiters: [Key: [(CGImage) -> Void]] = [:]
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

    /// The cache key of a row's bitmap: without the width for a width-invariant row
    /// (RowDraw.widthInvariant), so a divider drag or live resize shows the bitmap drawn at the
    /// previous width instead of drawing the same pixels again (the visible rows' bitmaps were
    /// about 6 % of main in a divider drag).
    static func key(_ spec: RowSpec, scale: CGFloat = Fixture.renderScale, space: CGColorSpace? = WideBitmap.drawSpace) -> Key {
        guard !TiledBubble.applies(spec), RowDraw.widthInvariant(spec) else { return Key(spec: spec, scale: scale, space: space) }
        var k = spec
        k.width = 0
        return Key(spec: k, scale: scale, space: space)
    }
    func image(for spec: RowSpec, scale: CGFloat = Fixture.renderScale) -> CGImage? { cache.value(for: RowBitmaps.key(spec, scale: scale)) } // dictionary read
    func has(_ spec: RowSpec, scale: CGFloat = Fixture.renderScale) -> Bool {
        TiledBubble.applies(spec) || cache.keys.contains(RowBitmaps.key(spec, scale: scale)) || waiters.keys.contains(Key(spec: spec, scale: scale))
    }

    /// Main thread: get the bitmap now or when it is rendered (at `scale`, the asking view's).
    func request(_ spec: RowSpec, scale: CGFloat = Fixture.renderScale, _ done: ((CGImage) -> Void)? = nil) {
        // Long text rows are tiles (TiledBubble.swift): no bitmap, and no spec (with its text) held here.
        // without the empty image (allocation failed) a tiled row has no bitmap to report.
        if TiledBubble.applies(spec) { if let empty = TiledBubble.emptyImage { done?(empty) }; return }
        if let img = cache[RowBitmaps.key(spec, scale: scale)] { done?(img); return }
        let w = Key(spec: spec, scale: scale)
        if waiters[w] != nil { if let done { waiters[w]?.append(done) }; return } // no force unwrap
        waiters[w] = done.map { [$0] } ?? []
        let gen = Fixture.paletteGeneration
        // Newest first: older pending renders drop a priority step (a fling's rows that left
        // the screen render after the rows now on it).
        for op in queue.operations where !op.isExecuting {
            switch op.queuePriority { case .veryHigh: op.queuePriority = .high; case .high: op.queuePriority = .normal
            case .normal: op.queuePriority = .low; default: op.queuePriority = .veryLow }
        }
        enqueue(w, gen, prefetch: done == nil)
    }

    private func enqueue(_ w: Key, _ gen: Int, prefetch: Bool) {
        let asked = CACurrentMediaTime()
        let spec = w.spec
        let op = BlockOperation {
            // Rows that left the screen before their turn are not drawn (no decode, no
            // idle backlog after a fling): a cell still waits for it, or it is a fresh prefetch.
            guard self.isWanted(spec) || (prefetch && CACurrentMediaTime() - asked < 0.5) else {
                DispatchQueue.main.async {
                    RowBitmaps.skipped += 1
                    // A cell may have asked again meanwhile: render for it, else forget the waiters.
                    if self.isWanted(spec), self.waiters[w] != nil { self.enqueue(w, gen, prefetch: false) }
                    else { self.waiters[w] = nil }
                }
                return
            }
            // a bitmap that could not be allocated is not delivered; the waiters are dropped
            // and the row shows no bitmap (BitmapFailure logged it).
            guard let img = RowBitmaps.render(spec, scale: w.scale) else {
                DispatchQueue.main.async { self.waiters[w] = nil }
                return
            }
            self.deliver(w, img, gen)
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
    private var pending: [(Key, CGImage, Int)] = []
    private func deliver(_ w: Key, _ img: CGImage, _ gen: Int) {
        pendingLock.lock()
        let first = pending.isEmpty
        pending.append((w, img, gen))
        pendingLock.unlock()
        guard first else { return }
        DispatchQueue.main.async {
            self.pendingLock.lock()
            let batch = self.pending
            self.pending = []
            self.pendingLock.unlock()
            if RowBitmaps.testHold { self.held += batch; return }
            self.apply(batch)
        }
    }

    /// Test only (scroller bench control, `--scroller-control --page`): while set, finished bitmaps
    /// wait on main instead of reaching their cells; `releaseHeld()` delivers them. The control
    /// holds them during each page slide, so rows slide in without text and the bench's empty-row
    /// check must find them.
    static var testHold = false
    private var held: [(Key, CGImage, Int)] = []
    func releaseHeld() {
        guard !held.isEmpty else { return }
        let batch = held
        held = []
        apply(batch)
    }

    private func apply(_ batch: [(Key, CGImage, Int)]) {
        for (w, img, gen) in batch {
            // Rendered with an older palette, or asked in another colour space than the current one (a display change
            // since the request): drop it and render again (in the current space).
            guard gen == Fixture.paletteGeneration, w.space == WideBitmap.drawSpace else {
                let ws = waiters.removeValue(forKey: w) ?? []
                for d in ws { request(w.spec, scale: w.scale, d) }
                if ws.isEmpty { request(w.spec, scale: w.scale) }
                continue
            }
            store(w.spec, img, scale: w.scale, space: w.space)
            waiters.removeValue(forKey: w)?.forEach { $0(img) }
        }
    }

    private func store(_ s: RowSpec, _ img: CGImage, scale: CGFloat, space: CGColorSpace?) {
        if TiledBubble.applies(s) { return }
        let spec = RowBitmaps.key(s, scale: scale, space: space)
        if let old = cache[spec] { bytes -= old.bytesPerRow * old.height } else { order.append(spec) }
        cache.updateValue(img, forKey: spec) // dictionary write
        bytes += img.bytesPerRow * img.height
        // Trim in chunks (removing from the front of the order array on every
        // insert copied it each time). Bounded by rows and by bytes (media rows are large).
        if order.count > RowBitmaps.capacity + 100 || bytes > RowBitmaps.byteBudget {
            var n = max(0, order.count - RowBitmaps.capacity), freed = 0
            if bytes > RowBitmaps.byteBudget {
                for spec in order.dropFirst(n) { // no index math
                    guard bytes - freed > RowBitmaps.byteBudget * 4 / 5 else { break }
                    freed += cache.value(for: spec).map { $0.bytesPerRow * $0.height } ?? 0
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

    /// Bitmaps rendered ahead of time (loader queue) at `scale`, inserted on main.
    /// Under the current colour space (WideBitmap.drawSpace). `generation`: the palette generation the items were
    /// drawn at (off main, before this call); a palette or colour space change since drops them (they are drawn again
    /// when asked).
    func insert(_ items: [(RowSpec, CGImage)], scale: CGFloat = Fixture.renderScale, generation: Int = Fixture.paletteGeneration) {
        guard generation == Fixture.paletteGeneration else { return }
        items.forEach { store($0.0, $0.1, scale: scale, space: WideBitmap.drawSpace) }
    }

    /// Test hook (`--scroller-control`): no bitmaps rendered ahead (pager prerender, scroll
    /// prefetch), so a check for rows without bitmaps has something to find.
    static var prerenderEnabled = true
    /// Render the rows that will be on screen first (loader queue), at `scale` (insert them with the same scale).
    static func prerender(_ specs: ArraySlice<RowSpec>, scale: CGFloat = Fixture.renderScale) -> [(RowSpec, CGImage)] {
        guard prerenderEnabled else { return [] }
        return specs.compactMap { spec in
            switch spec.kind { case .receipt, .typing: return nil; default: return render(spec, scale: scale).map { (spec, $0) } } // unallocated rows are skipped
        }
    }

    /// Thread safe. The drawing runs with `Fixture.renderScale` = `scale` on this thread (the balloon inset, the soft
    /// edge and image decodes read it).
    static func render(_ spec: RowSpec, scale: CGFloat = Fixture.renderScale) -> CGImage? { // nil when allocation fails
        if TiledBubble.applies(spec) { return TiledBubble.emptyImage }
        let span = RowDraw.drawSpan(spec)
        let size = CGSize(width: span.upperBound - span.lowerBound, height: spec.height + 2 * RowDraw.margin)
        return Fixture.withRenderScale(scale) {
            WideBitmap.make(size: size, scale: scale, opaque: false) { ctx in
                ctx.translateBy(x: -span.lowerBound, y: 0)
                RowDraw.drawStatic(spec, ctx, windowY: .nan)
            }
        }
    }
}

/// An 8-bit Display P3 bitmap with a y-down UIKit drawing context. The palette is
/// Display P3 (README: Colour); an sRGB bitmap clips the P3 colours outside sRGB
/// (the replies blue, the outgoing blues in the header backdrop). Same 4 bytes per
/// pixel as the sRGB `.standard` renderer it replaces. AppKit builds draw through the
/// shim's renderer, whose bitmaps are in the window's colour space already.
enum WideBitmap {
    static let space = LabColorSpace.displayP3 // no force unwrap
    /// The colour space `make` draws in now (the row bitmap cache's key): AppKit builds draw in the window's display
    /// space (DisplayScale.colorSpace, process-wide); UIKit builds in their renderer's own (one, so nil).
    static var drawSpace: CGColorSpace? {
        #if canImport(UIKit)
        return nil
        #else
        return DisplayScale.colorSpace
        #endif
    }
    /// nil when the bitmap cannot be allocated (a huge size, memory pressure); the
    /// caller draws nothing and BitmapFailure logs the first one (crash program, no trap).
    static func make(size: CGSize, scale: CGFloat, opaque: Bool, _ draw: (CGContext) -> Void) -> CGImage? {
        #if canImport(UIKit)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = opaque
        fmt.preferredRange = .extended
        return BitmapFailure.checked(UIGraphicsImageRenderer(size: size, format: fmt).image { draw($0.cgContext) }.cgImage, size: size)
        #else
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = opaque
        return BitmapFailure.checked(UIGraphicsImageRenderer(size: size, format: fmt).image { draw($0.cgContext) }.cgImage, size: size)
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
    static func drawBubble(_ ctx: CGContext, body: CGRect, lines: [String], outgoing: Bool, tail: Bool, windowY: CGFloat = 0,
                           cornersOf frame: CGSize? = nil, circularEnds: Bool = false) {
        drawBubble(ctx, shape: BubblePath.make(body: body, outgoing: outgoing, tail: tail, cornersOf: frame, circularEnds: circularEnds),
                   outgoing: outgoing, windowY: windowY)
    }
    /// cmux: fills `shape` (a part's `BubblePath.balloon`) as a bubble of its side.
    static func drawBubble(_ ctx: CGContext, shape: UIBezierPath, outgoing: Bool, windowY: CGFloat = 0) {
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

/// Thread preview colours. Here, not in `Fixture`, because ios/ compiles this file with its own `Fixture`.
/// (cmux: the quote's own colours are its source bubble's, `PartRenderer.drawQuoteBubble`.)
enum PreviewStyle {
    /// "N Replies" (thread previews and reply labels), Display P3 (screencapture -l).
    static let repliesBlue = Fixture.p3(63, 143, 247)
}
