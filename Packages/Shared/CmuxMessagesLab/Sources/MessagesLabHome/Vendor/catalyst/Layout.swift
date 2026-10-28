#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The render scale of the view whose work runs now on this thread (cx-3cb view-scale). Two window views can show at
/// two backing scales at the same time (cmux Home: windows on a 2x and a 1x display), so the scale is the view's own
/// (MessagesWindowView.renderScale, set by its setRenderScale), not one process value. Code that has its view uses
/// that value directly; the static drawing and layout helpers it calls (RowDraw, SoftBalloon, RowBitmaps.render,
/// ThreadPreview.height, Images.load) read `Fixture.renderScale`, which is the scope's value inside
/// `Fixture.withRenderScale(_:_:)` and the process fallback outside one. Work sent to another queue takes the scale
/// with it (a task local does not follow DispatchQueue blocks): RowBitmaps, Pager, TiledBody, MorphBubble.prepare.
enum RenderScaleScope {
    /// The scope's scale for work inside a Swift task or off the main thread.
    @TaskLocal static var scoped: CGFloat? = nil
    /// cmux: the scope's scale on the main thread outside any task (a layer's draw, a window
    /// move, a layout pass). A task local bound there lives in the thread's fallback storage, and an
    /// isolated deinit run inline under it (every main-actor class of a main-actor-default target
    /// has one) makes the macOS 15.4 to 15.x runtime free() a marker its task allocator made: cmux
    /// trapped under Chromium's allocator when Cmd-1 left Home (CMUXTERM-MACOS-44XN, macOS 15.8.1).
    // crash-allow: read and written only on the main thread (`with` and `current` check it).
    nonisolated(unsafe) static var mainThreadScoped: CGFloat? = nil

    /// The scale of the scope that runs now, nil outside any scope.
    static var current: CGFloat? { scoped ?? (Thread.isMainThread ? mainThreadScoped : nil) }

    /// Runs `body` in a scope of scale `s`, binding no task local where no task runs.
    static func with<T>(_ s: CGFloat, _ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread, !withUnsafeCurrentTask(body: { $0 != nil }) {
            let outer = mainThreadScoped
            mainThreadScoped = s
            defer { mainThreadScoped = outer }
            return try body()
        }
        // concurrency-allow: bound inside a task or off the main thread, never in fallback storage on main
        return try $scoped.withValue(s, operation: body)
    }
}

extension Fixture {
    /// Runs `body` with `Fixture.renderScale` = `s` on this thread (a scale of 0 or less: the current value).
    static func withRenderScale<T>(_ s: CGFloat, _ body: () throws -> T) rethrows -> T {
        guard s > 0, RenderScaleScope.current != s else { return try body() }
        return try RenderScaleScope.with(s, body)
    }
}

/// Text measured and wrapped with Core Text, the way the bubbles draw it.
struct TextLayout: Hashable {
    struct Line: Hashable {
        var range: NSRange; var width: CGFloat
        /// The width without the line's trailing whitespace: what the typesetter fits to the column
        /// (a wrapped line's trailing space hangs past it, `width` counts it). Infinity when unknown.
        var fit: CGFloat = .infinity
    }
    var text: String
    var runs: [TextRun]
    var lines: [Line]
    /// Widest line including a wrapped line's trailing space (measured rule).
    var width: CGFloat

    static func make(_ text: String, runs: [TextRun], maxWidth: CGFloat, font: UIFont = Fixture.bodyFont) -> TextLayout {
        // Measured with the faces the bubble draws: a bold or italic run (or a mention, drawn bold)
        // is wider than the plain body font, and the plain measure left the drawn text 8 pt past a
        // bubble's right padding (cmux-next's harness, 2026-10-10: m01 "Q3 plan" bold, right
        // padding 12 px against 26 px on the left). No kern, as the plain measure.
        let drawnFaces = font == Fixture.bodyFont && runs.contains { !($0.style ?? []).isEmpty || $0.mention != nil }
        let attr = drawnFaces
            ? TextLayout(text: text, runs: runs, lines: [], width: 0).attributed(color: .white, linkColor: .white, kern: 0)
            : NSAttributedString(string: text, attributes: [.font: font])
        let ts = CTTypesetterCreateWithAttributedString(attr)
        let len = (text as NSString).length
        var lines: [Line] = []
        var start = 0
        while start < len {
            var n = CTTypesetterSuggestLineBreak(ts, start, Double(maxWidth))
            if n <= 0 { n = 1 }
            var range = NSRange(location: start, length: n)
            // A hard newline ends the line but is not drawn or measured.
            let s = (text as NSString).substring(with: range)
            if s.hasSuffix("\n") { range.length -= 1 }
            // A blank line (the empty line of a paragraph break) is 0 pt wide: CTTypesetterCreateLine with
            // length 0 lays out the whole rest of the text, which made every text with a paragraph break
            // whose rest is longer than the column as wide as the column (cx-3cb wide-window: Messages'
            // 9-line "That's WebAuthn's ..." balloon is 738.5 pt in a 1192 pt pane, its widest line + 24;
            // ours was the column + 24, 751.3 pt).
            var w: CGFloat = 0, fit: CGFloat = 0
            if range.length > 0 {
                let line = CTTypesetterCreateLine(ts, CFRange(location: range.location, length: range.length))
                w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                fit = w - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            }
            lines.append(Line(range: range, width: w, fit: fit))
            start += n
            if start == len && s.hasSuffix("\n") { lines.append(Line(range: NSRange(location: len, length: 0), width: 0, fit: 0)) }
        }
        if lines.isEmpty { lines = [Line(range: NSRange(location: 0, length: 0), width: 0, fit: 0)] }
        return TextLayout(text: text, runs: runs, lines: lines, width: lines.map(\.width).max() ?? 0)
    }

    /// Attributed text for drawing (styles, links, mentions, detected data).
    func attributed(color: UIColor, linkColor: UIColor, kern: CGFloat = Fixture.bodyKern) -> NSAttributedString {
        let a = NSMutableAttributedString(string: text, attributes: [.font: Fixture.bodyFont, .foregroundColor: color, .kern: kern])
        for r in runs {
            // a run that does not fit this text is skipped: negative, or past the end
            // without overflowing (NSMaxRange of Int.max traps; addAttribute raises NSRangeException).
            guard let range = Self.range(r.start, r.length, in: a.length) else { continue }
            var traits: UIFontDescriptor.SymbolicTraits = []
            for s in r.style ?? [] {
                switch s {
                case "bold": traits.insert(.traitBold)
                case "italic": traits.insert(.traitItalic)
                case "underline": a.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                case "strikethrough": a.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                // cmux: a quoted excerpt (Reply to Selection, a Markdown `>` line) in the text's own colour at 66 %.
                case "quote": a.addAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * 0.66), range: range)
                default: break
                }
            }
            if r.mention != nil { traits.insert(.traitBold) }
            // cmux: the bold/italic face held for the process (HomeFonts, cx-qpqs); no font attribute when there is none.
            if !traits.isEmpty, let f = HomeFonts.font(Fixture.bodyFont, adding: traits) {
                a.addAttribute(.font, value: f, range: range)
            }
            // cmux: inline code and code blocks (HomeMarkdown) in the monospaced system font, one point smaller like Messages' body.
            // One font for the process (HomeFonts.code): one made per run on RowBitmaps' threads came back nil.
            if r.style?.contains("code") == true {
                a.addAttribute(.font, value: HomeFonts.code, range: range)
            }
            if r.link != nil {
                a.addAttributes([.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
            if r.detected != nil { a.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        HomeLinkChip.reserve(in: a, runs: runs, kern: kern)
        return a
    }

    /// `start..<start+length` as a range when it lies inside a text of
    /// `count` UTF-16 units, else nil. No arithmetic can overflow.
    static func range(_ start: Int, _ length: Int, in count: Int) -> NSRange? {
        guard start >= 0, length >= 0, start <= count, length <= count - start else { return nil }
        return NSRange(location: start, length: length)
    }

    /// A line after a hard newline advances as far as a wrapped line, on both
    /// sides (measured: a received 19-line bubble with 13 newlines is 19 x 16 pt;
    /// the recording's sent 3-line bubble is 14 + 3 x 16 = 62 pt).
    static let hardBreakAdvance: CGFloat = Fixture.lineHeight
    /// `hard`: the advance after a hard newline. 16 pt for received text
    /// (a 19-line received bubble with 13 newlines is exactly 19 x 16 pt);
    /// 15.5 pt was measured on the one sent multiline bubble of the recording.
    func lineOffset(_ i: Int, hard: CGFloat = 16) -> CGFloat {
        var y: CGFloat = 0
        let ns = text as NSString
        let hardAdvance = hard
        for line in lines.prefix(max(1, i + 1)).dropFirst() { // no index math
            let loc = line.range.location
            let hard = loc > 0 && loc <= ns.length && ns.character(at: loc - 1) == 10
            y += hard ? hardAdvance : Fixture.lineHeight
        }
        return y
    }
    func textHeight(hard: CGFloat) -> CGFloat { lineOffset(lines.count - 1, hard: hard) + Fixture.lineHeight }

    /// The link at a point relative to the text origin (first line top).
    func link(at p: CGPoint) -> String? {
        let i = CrashGuard.int(floor(p.y / Fixture.lineHeight), in: CrashGuard.countRange) // no trap on NaN
        guard i >= 0, i < lines.count, let lineRange = lines[checked: i]?.range else { return nil } // checked
        let attr = attributed(color: .white, linkColor: .white)
        // lines measured for another text (stale during an edit or a streamed reply) are not read past the end.
        guard Self.range(lineRange.location, lineRange.length, in: attr.length) != nil else { return nil }
        let line = CTLineCreateWithAttributedString(attr.attributedSubstring(from: lineRange))
        let idx = CTLineGetStringIndexForPosition(line, CGPoint(x: p.x, y: 0)) + lineRange.location
        return runs.first { $0.link != nil && idx >= $0.start && idx < $0.start + $0.length }?.link
    }
}

/// Width-dependent geometry. At the fixture width every value equals the
/// measured constant; wider windows move right-aligned content with the right
/// edge and grow the text column in proportion.
struct Metrics: Hashable {
    var width: CGFloat
    /// The window's current layout width (main thread only). Off-main work
    /// takes the width as a parameter captured on main.
    static var current = Metrics(width: Fixture.windowWidth)

    var dx: CGFloat { width - Fixture.windowWidth }
    var rightEdge: CGFloat { Fixture.rightEdge + dx }
    var centerX: CGFloat { Fixture.centerX + dx / 2 }
    var receiptRight: CGFloat { Fixture.receiptRight + dx }
    /// Text column: 358.4 pt at the 628 pt window, then 0.654 pt per point of window width, with no
    /// upper cap: Messages' column follows the same rule in wide panes (cx-3cb wide-window, macOS 27, a
    /// 320 pt sidebar: panes 480, 680, 920 and 1192 pt bound it to [260.5, 263.5], [390.75, 393.5],
    /// [544, 553.25] and [713, 729]; the rule gives 261.6, 392.4, 549.4 and 727.3;
    /// tools/evidence/anim/colwidth).
    /// Measured on macOS 27 Messages at 434, 480, 520, 560 and 600 pt (lossless stills,
    /// references/real-messages/recordings/stills/widths; line breaks bound it per width to
    /// [226,232), [260,273), [287.5,294), [304.5,319.5), >= 338; 0.654 is inside all five). The old rule, proportional to
    /// the width (0.5707 W), wrapped later than Messages below 600 pt.
    var maxTextWidth: CGFloat {
        // A cmux-next Home pane can be narrower than Messages' 434 pt window minimum (the
        // pane layout has no per-content minimum): below 434 pt the column keeps its
        // 434 pt share of the width (the rule alone reaches 0 pt at 80 pt).
        guard width < 434 else { return ((Fixture.maxTextWidth - 0.654 * (Fixture.windowWidth - width)) * 10).rounded() / 10 }
        return (((Fixture.maxTextWidth - 0.654 * (Fixture.windowWidth - 434)) * width / 434) * 10).rounded() / 10
    }
    var maxLinkWidth: CGFloat { min(Fixture.maxLinkWidth, maxTextWidth + 2 * Fixture.bubblePadX) }
    var mediaWidth: CGFloat { min(Fixture.mediaWidth, maxTextWidth + 2 * Fixture.bubblePadX) }
}

/// One row of the transcript. Rows are derived from state, never stored.
struct RowSpec: Hashable {
    var key: String
    var kind: Kind
    /// Space above the content.
    var gap: CGFloat
    /// Content height.
    var height: CGFloat
    /// Layout width the row was derived for (positions and bitmaps use it).
    var width: CGFloat = Fixture.windowWidth
    /// Height estimated from another width (lazy re-measure after a resize).
    var estimated = false
    var metrics: Metrics { Metrics(width: width) }
    /// The height in this row a thread connector's arc hangs from (row coordinates): its vertical middle.
    var connectorAnchorY: CGFloat { height / 2 }

    /// Cheap hash: the key plus geometry. Equality still compares everything,
    /// so specs that differ only in content collide and are told apart by ==.
    /// (The synthesized hash walked every string with NFC normalization; the
    /// bitmap cache hashes specs many times per frame.)
    func hash(into h: inout Hasher) {
        h.combine(key)
        h.combine(height)
        h.combine(width)
        h.combine(gap)
    }
    var total: CGFloat { gap + height }

    enum Kind: Hashable {
        case separator(bold: String, rest: String)
        case unsent(outgoing: Bool)
        case part(PartRow)
        case label(text: String, outgoing: Bool, color: LabelColor)    // Edited, Not Delivered
        case replies(count: Int, root: PartRef, outgoing: Bool)
        case receipt(bold: String, rest: String)
        case typing
        /// The host's status line under the transcript (ask 9, HostHooks.swift): one line of centered secondary text.
        case notice(String)
        /// A copy of a thread's root above a reply whose root is not directly
        /// above it (macOS 26): a mini card or thumbnail, a short stub, and
        /// "N Replies" when the thread has 2 or more replies.
        case threadPreview(ThreadPreview)
        /// cmux: a group chat's sender name above the first bubble of another person's run (iMessage): small
        /// secondary text at the incoming bubbles' text edge. Key "name:<message id>".
        case senderName(String)
    }
    enum LabelColor: Hashable { case secondary, failure, link }
}

/// Compose bar geometry shared by every app (catalyst, ios, appkit-native). Measured on
/// macOS 27 Messages (lossless references, 2026-10-05; macOS 26 values in brackets): the
/// one-line field is 31 pt tall [30] with its bottom unchanged, so the transcript ends 1 pt
/// higher (983 [984]); 2 and 3 lines are 47 and 63 pt; the first baseline is 20.25 pt below
/// the field top on both.
/// After a send the empty field is 30 pt on both (`emptyAfterSend`), until a character is typed:
/// lossless macOS 27 takes (send-1line-take2, send-2line-take2, send-1line-unfocused-take2,
/// send-1line-2bubble-take1, send-typed-take1, send-typed-media-take1, typing-unfocused-take1,
/// reply-menu-send-take1; cx-3cb compose-settle, 2026-10-11): every take starts at 30 pt (the
/// previous take's send), the first typed character makes it 31, the send settles it at 30
/// again (top 1000, caret and placeholder 1 pt lower with the top); a click, a deactivation or
/// the reply view's Esc leave it at 30. An empty field that was never sent from (launch, a
/// draft deleted with Backspace or Cmd-A Delete) is 31 (deactivate-activate, field-focus-type).
/// The macOS 26 recording's [30] and its baseline were measured after its send: the same 30 pt
/// field, placeholder (top + 10.5) and caret (top + 7) as macOS 27's, and its 2- and 3-line
/// drafts have the 20.25 baseline. Its empty field before a send is not recorded (the 30 stays).
/// The Mac apps pick the values of the OS they run on (a run-time check: one build runs on
/// both); macOS 26 values come from the macOS 26 recording (catalyst/TRANSITIONS.md). iOS keeps
/// the macOS 27 values.
enum ComposeMetrics {
    /// Running on macOS 26 (before 27). `MESSAGESLAB_OS_FIT=26|27` overrides it (A/B checks only).
    static let macOS26: Bool = {
        #if os(macOS) || targetEnvironment(macCatalyst)
        switch ProcessInfo.processInfo.environment["MESSAGESLAB_OS_FIT"] {
        case "26": return true
        case "27": return false
        default: return ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
        }
        #else
        return false
        #endif
    }()
    static func height(lines: Int, chips: Bool) -> CGFloat {
        (lines == 1 ? oneLine : 31 + 16 * CGFloat(lines - 1)) + (chips ? 30 : 0)
    }
    static let oneLine: CGFloat = macOS26 ? 30 : 31
    static let anchorBase: CGFloat = macOS26 ? 984 : 983
    static let fieldBottom: CGFloat = 1030.25
    static let firstBaseline: CGFloat = 20.25
    /// The empty field after a send (see above): 1 pt under the macOS 27 one-line field, its bottom unchanged.
    static let emptyAfterSend: CGFloat = 30
}

struct ThreadPreview: Hashable {
    var root: PartRef
    /// The root part, when it is loaded (else a generic preview).
    var part: Part?
    var count: Int
    /// The root is mine: the preview shows on the right (macOS 27, outgoing-thread-reply-take4, the
    /// "Maybe: Instinct" reference of 2026-10-11): an outlined outgoing bubble at the right edge in blue,
    /// "N Replies" right-aligned under it, no stub. A preview follows its root's side, not the reply's
    /// (a reply of mine to Instinct's "Charlie." shows its preview on the left, reply-from-menu-send).
    var outgoing = false
    /// Measured layout (points, relative to the row's content top).
    var box: CGSize
    static let stubGap: CGFloat = 3.5, stubHeight: CGFloat = 12.5
    /// Space between the stub and the reply below.
    static let replyGap: CGFloat = 7
    /// cmux: the quote is its source bubble (fill, text colour, rounding) drawn at this opacity, so it
    /// reads as context under the live bubbles (plans/cmux-next/reply-thread-gallery.html, variant A).
    static let quoteOpacity: CGFloat = 0.55
    /// Body bottom of the row above to the preview's top (measured 31.5).
    static let gap: CGFloat = 31.5
    var isThumbnail: Bool {
        if case let .attachment(a) = part, a.kind == "image" || a.kind == "video" { return true }
        return false
    }
    /// Measured on 2x screenshots of macOS 26 Messages: link/text card
    /// 180.5 x 48.5 (text 39 pt in, 15 pt right padding); photo thumbnail
    /// 48 pt wide at the photo's aspect.
    /// `width`: the transcript's layout width (a text root wraps in the bubble column, so its
    /// preview's size depends on it; `RowBuilder.rewidth` makes the preview again).
    static func make(root: PartRef, part: Part?, count: Int, outgoing: Bool = false, width: CGFloat = Fixture.windowWidth) -> ThreadPreview {
        var p = ThreadPreview(root: root, part: part, count: count, outgoing: outgoing, box: .zero)
        if p.isThumbnail, case let .attachment(a) = part {
            p.box = CGSize(width: 48, height: (48 * CGFloat(a.height ?? 450) / CGFloat(max(1, a.width ?? 600))).rounded())
        } else if case let .text(t, _) = part {
            let maxBox = ThreadPreview.maxTextBoxWidth(width: width)
            p.textLines = ThreadPreview.wrap(t, maxWidth: maxBox - ThreadPreview.textPadX)
            let one = p.textLines.count == 1 ? p.textLines.first.map { TextDraw.width($0, font: ThreadPreview.textFont) } : nil
            p.box = CGSize(width: one.map { min(maxBox, ($0 + ThreadPreview.textPadX).rounded(.toNearestOrEven)) } ?? maxBox,
                           height: ThreadPreview.textHeight(lines: p.textLines.count))
        } else {
            let (title, sub) = p.lines
            let w = max(TextDraw.width(title, font: ThreadPreview.titleFont), TextDraw.width(sub, font: ThreadPreview.subFont))
            p.box = CGSize(width: min(300, (39 + w + 15).rounded()), height: 48.5)
        }
        return p
    }
    /// cmux: a text root (2026-10-20, plans/cmux-next/reply-thread-gallery.html variant A): a smaller copy of the
    /// root's own bubble, its fill and text colour at `quoteOpacity`, 12 pt text a bubble's 12 pt in from each end, 28 pt
    /// tall for one line (half-circle ends, as a real one-line bubble), 46 pt for 2 (a 2-line bubble's corners), at most 2 lines
    /// with "…" at the end of the last, and no tail (a quote is never the last bubble of a run). A wrapped root
    /// takes the full quote column; the column scales with the bubble column (`Metrics.maxTextWidth`). It
    /// replaces the outlined 10 pt copy of macOS Messages' preview, which did not look like the quoted bubble.
    var isText: Bool { if case .text = part { return true }; return false }
    static let textFont = UIFont.systemFont(ofSize: 12)
    /// The text's lines as drawn (text roots only; one line when it fits).
    var textLines: [String] = []
    /// cmux: bubble edge to text plus text to bubble edge: a bubble's padding (`Fixture.bubblePadX`) on each side.
    static let textPadX: CGFloat = 2 * Fixture.bubblePadX
    /// cmux: a one-line quote's height (under 30 pt, so its ends are half circles as a 1-line bubble's).
    static let textOneLineHeight: CGFloat = 28
    /// Baseline to baseline of a wrapped root.
    static let textLinePitch: CGFloat = 15
    static let maxTextLines = 2
    /// cmux: the quote's height for `lines` lines: 28 pt for one; a wrapped quote is at least 46 pt, a 2-line bubble's
    /// height, so it keeps the bubbles' 15 pt continuous corner (a shorter body takes UIKit's pill corner).
    static func textHeight(lines: Int) -> CGFloat {
        lines <= 1 ? textOneLineHeight : max(46, textOneLineHeight + textLinePitch * CGFloat(lines - 1))
    }
    /// cmux: the first baseline under the quote's top: the lines centred in the quote.
    func textFirstBaseline() -> CGFloat {
        let f = ThreadPreview.textFont
        let lineH = f.ascender - f.descender
        let block = lineH + ThreadPreview.textLinePitch * CGFloat(max(0, textLines.count - 1))
        return ((box.height - block) / 2 + f.ascender).rounded(.toNearestOrEven)
    }
    /// cmux: the quote's shape as a row: a part of the root's side, the quote's size, no tail (a quote is never the
    /// last bubble of a run). `BubblePath.balloon` of this row is the quote's outline, the same rule as every bubble.
    var shapeRow: PartRow {
        PartRow(ref: root, part: part ?? .text("", runs: []), outgoing: outgoing, tail: false, reactions: [], failed: false,
                size: box, text: nil, connectorRoot: nil)
    }
    /// The widest text preview (outline outside): 383 pt at the 628 pt window (outside 225.0-608.5 pt
    /// measured; our outline's right edge is the bubbles' 608), with the bubble column at other widths.
    static func maxTextBoxWidth(width: CGFloat) -> CGFloat { Metrics(width: width).maxTextWidth + 24.6 }
    /// Word-wrapped lines of a root text at `maxWidth` (newlines read as spaces, as before), at most
    /// `maxTextLines`; the last line ends in "…" when text is left over.
    static func wrap(_ text: String, maxWidth: CGFloat) -> [String] {
        // A root can be a 100k-character message: only the characters that 4 lines can hold are laid out
        // (no 10 pt glyph is narrower than 2 pt, so 2 per pt of width is more than 4 lines), at most 2000;
        // a cut text always ends in "…".
        let limit = 16 + 2 * CrashGuard.int(maxWidth.isFinite ? min(992, max(0, maxWidth)) : 0, in: 0...992)
        let head = text.prefix(limit)
        let cut = head.endIndex < text.endIndex
        let flat = String(head).replacingOccurrences(of: "\n", with: " ")
        let tl = TextLayout.make(flat, runs: [], maxWidth: maxWidth, font: textFont)
        let ns = flat as NSString
        var lines: [String] = []
        for (i, line) in tl.lines.enumerated() {
            let last = i == maxTextLines - 1 || i == tl.lines.count - 1
            guard !last || tl.lines.count <= maxTextLines && !cut else {
                // The last allowed line: the rest of the text, cut to fit with "…" (tail truncation).
                let rest = ns.substring(from: line.range.location)
                lines.append(truncate(rest, maxWidth: maxWidth))
                break
            }
            guard TextLayout.range(line.range.location, line.range.length, in: ns.length) != nil else { break }
            lines.append(ns.substring(with: line.range))
        }
        return lines.isEmpty ? [""] : lines
    }
    /// `s` cut at the last character that leaves room for "…", trailing spaces dropped, then "…".
    static func truncate(_ s: String, maxWidth: CGFloat) -> String {
        let room = maxWidth - TextDraw.width("…", font: textFont)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: textFont]))
        let n = CTLineGetStringIndexForPosition(line, CGPoint(x: max(0, room), y: 0))
        let ns = s as NSString
        let cut = n == kCFNotFound ? ns.length : min(max(0, n), ns.length)
        // A composed character is never split.
        let safe = cut < ns.length ? ns.rangeOfComposedCharacterSequence(at: cut).location : cut
        var head = ns.substring(to: safe)
        while head.last == " " { head.removeLast() }
        return head + "…"
    }
    static let titleFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
    static let subFont = UIFont.systemFont(ofSize: 12)
    /// Title and second line of the card.
    var lines: (String, String) {
        switch part {
        case let .link(url, title, site, _, _): return (title ?? site ?? url, site ?? url)
        case let .text(t, _):
            let one = String(t.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            return (String(one.prefix(28)), one.count > 28 ? String(one.dropFirst(28).prefix(30)) : "")
        case let .attachment(a): return (a.fileName, Format.bytes(a.byteSize))
        case let .location(_, _, title, _): return (title ?? Strings.location, "")
        case let .custom(c): return (CustomRows.plainText(c), "")
        case nil: return ("…", "")
        }
    }
    /// Row content height: box, stub.
    /// Box to stub: 3.5 pt under a card, 5.5 pt under a thumbnail (its tail is between).
    /// Text previews (macOS 27, lossless stills): stub 5.15 pt under the box, 12.25 pt long.
    var stubGap: CGFloat { isThumbnail ? 5.5 : isText ? 5.15 : ThreadPreview.stubGap }
    var stubHeight: CGFloat { isThumbnail ? 11.5 : isText ? 12.25 : ThreadPreview.stubHeight }
    /// The row's height: box, stub, rounded to the device pixel grid (Fixture.renderScale). A text preview's parts are
    /// 41.65 pt (24.25 + 5.15 + 12.25; 52.65 with 2 lines); Messages' rows under a preview sit on whole device pixels
    /// (nosb-active against deactivate-activate tp0000ms: incoming edges 798.00 / 864.00 px, ours were 798.31 / 864.31
    /// with 41.65), so its preview row is 41.5 pt at 2x. The drawing keeps its measured places from the row's top: the
    /// stub's end lies 0.15 pt inside the reply gap (cx-3cb row-snap).
    var height: CGFloat { height(scale: Fixture.renderScale) }
    /// The height at a view's own scale (a window view derives its rows at its renderScale: two views on displays of
    /// two scales round the same preview to their own grids).
    func height(scale: CGFloat) -> CGFloat {
        let s = max(1, scale)
        return ((box.height + stubGap + stubHeight) * s).rounded() / s
    }
}

struct PartRow: Hashable {
    var ref: PartRef
    var part: Part
    var outgoing: Bool
    var tail: Bool
    var reactions: [Reaction]
    /// The index in `reactions` of the viewer's own reaction (the participant with isMe,
    /// AppState.me, of the conversation this row was built from), or nil. The row carries it, not
    /// a process global: two windows with different users draw their own badges blue, and the
    /// off-main renderers read no shared state. Part of the row's equality and hash, so the row
    /// bitmap and badge caches re-render when it changes. The engine keeps one reaction per
    /// person per part; with more, the first one is mine.
    var myReaction: Int? = nil
    var failed: Bool
    var size: CGSize
    var text: TextLayout?
    /// Key of the root row when this row draws a thread connector.
    var connectorRoot: String?
    /// Markdown text (MarkdownLayout.swift): drawn and hit-tested from this; `text` is then a
    /// one-line proxy of the display string.
    var markdown: MarkdownLayout? = nil
    /// The message is marked markdown (Message.format): a long text part takes the markdown
    /// tiles only then (LongTextStore.layout).
    var markdownFormat: Bool = false
    /// cmux: the sender's avatar beside this bubble (a group chat, the last bubble of another person's run).
    var cmuxAvatar: SenderAvatar? = nil
    /// cmux: how far right of `Fixture.leftEdge` an incoming bubble sits (a group chat's avatar column,
    /// `SenderAvatar.bubbleInset`; 0 elsewhere). Outgoing rows ignore it.
    var cmuxIndent: CGFloat = 0
    /// cmux: the body's left edge in row coordinates (`rightEdge`: the row's `Metrics.rightEdge`).
    func cmuxBodyX(rightEdge: CGFloat) -> CGFloat { outgoing ? rightEdge - size.width : Fixture.leftEdge + cmuxIndent }
    /// The message format of this row (Message.format).
    var format: MessageFormat? { markdownFormat ? .markdown : nil }
    /// The drawn body: lines after a hard newline are 15.5 pt apart, so the
    /// body is shorter than its 16 pt-per-line slot and sits at the slot top
    /// (measured on the sent 3-line bubble: top matches, bottom 1 pt higher).
    var bodySize: CGSize {
        guard let text, markdown == nil else { return size }
        guard outgoing else { return size }
        return CGSize(width: size.width, height: min(size.height, text.textHeight(hard: TextLayout.hardBreakAdvance) + 2 * Fixture.bubblePadY))
    }
}

enum Sizing {
    /// A text balloon's frame width: its widest line (typographic width with a wrapped line's trailing space, at most
    /// the column) plus 12 pt on each side, rounded UP to whole device pixels. Messages (macOS 27 and 26) does this on
    /// both sides (cx-3cb incoming-width, tools/evidence/ANIMATIONS.md, tools/evidence/anim/balwidth): the accessibility
    /// frames of 50 balloons in the reference scenes (ax-scene.json, round 3-6) are ceil(2 (t + 24)) / 2 pt exactly, and
    /// 117 balloons in the lossless stills (incoming right edges, outgoing left edges; windows 434-628 pt) are within
    /// 0.09 px of it; without the rounding the frames were 0.01-0.50 pt narrower. The grid is the view's scale
    /// (`scale`, its renderScale; cx-3cb view-scale: whole pixels at 1x too); measurements are cached per scale
    /// (MeasureCache.Key). The iOS app keeps the unrounded width (no reference).
    static func textBalloonWidth(_ text: CGFloat, column: CGFloat, scale: CGFloat = Fixture.renderScale) -> CGFloat {
        let w = min(text, column) + 2 * Fixture.bubblePadX
#if os(iOS) && !targetEnvironment(macCatalyst)
        return w
#else
        // 1e-4 px: a width on the grid stays there (no step up from float noise).
        let g = max(1, scale)
        return (w * g - 1e-4).rounded(.up) / g
#endif
    }

    /// `scale`: the view's (text balloon widths end on its device pixels).
    static func size(of part: Part, width: CGFloat, scale: CGFloat = Fixture.renderScale) -> (CGSize, TextLayout?) {
        let m = Metrics(width: width)
        let maxTextWidth = m.maxTextWidth, mediaWidth = m.mediaWidth
        switch part {
        case let .text(t, runs):
            let tl = TextLayout.make(t, runs: runs, maxWidth: maxTextWidth)
            let w = Sizing.textBalloonWidth(tl.width, column: maxTextWidth, scale: scale)
            return (CGSize(width: w, height: CGFloat(tl.lines.count) * Fixture.lineHeight + 2 * Fixture.bubblePadY), tl)
        case let .link(_, title, site, image, _):
            if Sizing.linkPending(title: title, site: site, image: image) { return (Sizing.linkPlaceholder, nil) }
            let (w, ih) = linkImageSize(image, maxWidth: m.maxLinkWidth)
            let lines = linkTitleLines(title ?? "", width: w)
            return (CGSize(width: w, height: ih + linkCaptionHeight(lines: lines.count)), nil)
        case let .attachment(a):
            switch a.kind {
            case "image", "video":
                // Natural size at 2x, up to 300 pt wide (measured: a 600 px photo is 300 x 225).
                var pw = CGFloat(a.width ?? 480), ph = CGFloat(a.height ?? 360)
                // Never larger than the source pixels allow (resolution brief):
                // a 354 px asset is at most 177 pt wide at 2x, whatever the metadata says.
                // Pixel size from metadata (MediaCache): no decode to size a row.
                if let ref = a.kind == "video" ? (a.poster ?? a.asset) : a.asset, let px = Images.pixelSize(ref) {
                    let srcW = px.width
                    if srcW < pw { ph = ph * srcW / pw; pw = srcW }
                }
                let w = min(max(mediaWidth, min(300, m.maxTextWidth + 2 * Fixture.bubblePadX)), pw / 2)
                return (CGSize(width: w, height: min(360, (w * ph / pw).rounded())), nil)
            case "voiceMemo": return (CGSize(width: 196, height: 36), nil)
            case "contact": return (CGSize(width: 250, height: 56), nil)
            // File and audio rows (measured): 275 x 89.5, icon centred.
            // cmux: a file card is as wide as its text needs (HomeFileCard, #26395).
            default: return (HomeFileCard.size(a, maxWidth: m.maxTextWidth + 2 * Fixture.bubblePadX), nil)
            }
        case let .location(lat, lon, _, _):
            // A map snapshot (macOS 26): 500 pt wide, caption inside; its
            // layout slot ends 5 pt above the image (measured: the next row
            // overlaps the snapshot's bottom).
            if let img = Images.mapSnapshot(lat, lon) {
                let w = min(500, img.size.width)
                return (CGSize(width: w, height: (w * img.size.height / img.size.width).rounded() - Images.mapOverhang), nil)
            }
            return (CGSize(width: mediaWidth, height: 150 + 44), nil)
        case let .custom(c):
            let (s, tl, _) = CustomRows.measure(c, message: nil, part: -1, width: width)
            return (s, tl)
        }
    }

    /// Link previews: the image at its 2x point size, width capped at 350.
    /// A link whose metadata is still loading: Messages shows a grey rounded
    /// square (137.5 x 103.5 pt, 15 pt corners, no tail; lossless take
    /// link-url-and-text, t+0.6-1.9 s) until the card replaces it.
    static let linkPlaceholder = CGSize(width: 137.5, height: 103.5)
    static func linkPending(title: String?, site: String?, image: String?) -> Bool { title == nil && site == nil && image == nil }

    static func linkImageSize(_ image: String?, maxWidth: CGFloat = Fixture.maxLinkWidth) -> (CGFloat, CGFloat) {
        // Raster previews are sized from metadata (no decode while rows are derived); an asset
        // with a vector sibling keeps the drawn image's size.
        if let image, !VectorAsset.hasSibling(image), let px = Images.pixelSize(image) {
            let w = min(maxWidth, px.width / 2)
            return (w, w * px.height / px.width)
        }
        guard let image, let img = Images.load(image) else { return (min(266, maxWidth), 0) }
        let px = img.size.width * img.scale, py = img.size.height * img.scale
        let w = min(maxWidth, px / 2)
        return (w, w * py / px)
    }
    static let linkTitleFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
    static func linkTitleLines(_ title: String, width: CGFloat) -> [String] {
        let tl = TextLayout.make(title, runs: [], maxWidth: width - 20, font: linkTitleFont)
        let ns = title as NSString
        var lines = tl.lines.map { ns.substring(with: $0.range) }
        if lines.count > 2 { lines = Array(lines.prefix(2)); lines[1] = lines[1].trimmingCharacters(in: .whitespaces) + "…" }
        return lines
    }
    static func linkCaptionHeight(lines: Int) -> CGFloat { 32.5 + 12 * CGFloat(max(1, lines)) }
}

enum Images {
    /// Pixel density of the bundled raster assets (2x crops): it fixes their
    /// point size, not the scale they are drawn at.
    static let assetScale: CGFloat = 2
    /// Map snapshots are assets named `real/map-<lat>_<lon>.png` (no network).
    static let mapOverhang: CGFloat = 5
    static func mapSnapshot(_ lat: Double, _ lon: Double) -> UIImage? { load(String(format: "real/map-%.4f_%.4f.png", lat, lon)) }
    /// Assets are 2x bitmaps (their point size is pixels / 2). An asset with
    /// a vector sibling (`name.svg`, see `VectorAsset`) is drawn from the
    /// vector at the current render scale instead, at the same point size.
    /// Thread safe; decoded once per scale into MediaCache (bounded by bytes;
    /// sources above 2048 px are decoded downsampled).
    static func load(_ ref: String) -> UIImage? {
        let scale = Fixture.renderScale
        let key = ref + "@" + String(describing: scale)
        if let c = MediaCache.shared.cached(key) { return c }
        if let v = VectorAsset.image(for: ref, scale: scale) {
            MediaCache.shared.store(key, v)
            return v
        }
        guard let img = MediaCache.shared.decode(Fixtures.assetURL(ref), scale: Images.assetScale) else { return nil }
        MediaCache.shared.store(key, img)
        return img
    }
}

/// Vector assets: `shared/assets/<name>.svg` next to `<name>.png`. Only the
/// subset `tools/vectorize_logo.py` writes is read: `<rect>` fills and
/// `<path d>` with absolute M/C/L/Z, in the PNG's pixel space.
enum VectorAsset {
    static func image(for ref: String, scale: CGFloat) -> UIImage? {
        guard !ref.hasPrefix("file:"), ref.hasSuffix(".png") else { return nil }
        let url = Fixtures.assetURL(String(ref.dropLast(4)) + ".svg")
        guard let text = try? String(contentsOf: url, encoding: .utf8), let (px, shapes) = parse(text) else { return nil }
        let size = CGSize(width: px.width / Images.assetScale, height: px.height / Images.assetScale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            c.scaleBy(x: 1 / Images.assetScale, y: 1 / Images.assetScale)
            for (path, color) in shapes {
                c.addPath(path)
                c.setFillColor(color.cgColor)
                c.fillPath()
            }
        }
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        guard let r = tag.range(of: name + "=\"") else { return nil }
        let rest = tag.suffix(from: r.upperBound) // no range subscripts
        return rest.firstIndex(of: "\"").map { String(rest.prefix(upTo: $0)) }
    }

    private static func color(_ hex: String?) -> UIColor {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return .black }
        return UIColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    static func parse(_ text: String) -> (CGSize, [(CGPath, UIColor)])? {
        guard let svg = text.range(of: "<svg").map({ String(text.suffix(from: $0.lowerBound).prefix(while: { $0 != ">" })) /* no range subscript */ }),
              let w = attr(svg, "width").flatMap(Double.init), let h = attr(svg, "height").flatMap(Double.init) else { return nil }
        var shapes: [(CGPath, UIColor)] = []
        var rest = Substring(text)
        while let r = rest.range(of: "<") {
            let tag = String(rest.suffix(from: r.lowerBound).prefix(while: { $0 != ">" })) // no range subscripts
            rest = rest.suffix(from: r.upperBound)
            if tag.hasPrefix("<rect") {
                let v = ["x", "y", "width", "height"].map { attr(tag, $0).flatMap(Double.init) ?? 0 }
                shapes.append((CGPath(rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), transform: nil), color(attr(tag, "fill"))))
            } else if tag.hasPrefix("<path"), let d = attr(tag, "d") {
                shapes.append((path(d), color(attr(tag, "fill"))))
            }
        }
        return (CGSize(width: w, height: h), shapes)
    }

    /// Absolute M, C, L, Z.
    static func path(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var cmd: Character = "M"
        var nums: [Double] = []
        func flush() {
            switch cmd {
            case "M": if nums.count >= 2 { p.move(to: CGPoint(x: nums[0], y: nums[1])) }
            case "L": if nums.count >= 2 { p.addLine(to: CGPoint(x: nums[0], y: nums[1])) }
            case "C":
                var rest = ArraySlice(nums) // six numbers at a time, no index math
                while rest.count >= 6 {
                    var n = rest.prefix(6).makeIterator()
                    if let x1 = n.next(), let y1 = n.next(), let x2 = n.next(), let y2 = n.next(), let x = n.next(), let y = n.next() {
                        p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
                    }
                    rest = rest.dropFirst(6)
                }
            case "Z": p.closeSubpath()
            default: break
            }
            nums.removeAll(keepingCapacity: true)
        }
        var token = ""
        for ch in d + " " {
            if "MCLZ".contains(ch) {
                if !token.isEmpty, let v = Double(token) { nums.append(v) }
                token = ""
                flush(); cmd = ch
                if ch == "Z" { flush() }
            } else if ch == " " || ch == "," || ch == "\n" {
                if !token.isEmpty, let v = Double(token) { nums.append(v) }
                token = ""
            } else {
                token.append(ch)
            }
        }
        if !token.isEmpty, let v = Double(token) { nums.append(v) }
        flush()
        return p
    }
}

/// Row measurements keyed by (message id, part, content version, width).
/// Filled off the main thread when pages load; the main thread only reads.
final class MeasureCache: @unchecked Sendable {
    static let shared = MeasureCache()
    /// `markdown`: the message's format (Message.format). A plain/markdown change under the same
    /// id and text (a host marking a message later, a local echo) is a new measurement.
    /// `scale`: the asking view's render scale (text balloon widths end on its device pixels; two views at two
    /// scales keep their own measurements).
    struct Key: Hashable { var id: ID; var part: Int; var version: Int; var width: CGFloat; var markdown: Bool; var scale: CGFloat }
    struct PartKey: Hashable { var id: ID; var part: Int; var version: Int; var markdown: Bool; var scale: CGFloat }
    struct Value { var size: CGSize; var text: TextLayout?; var width: CGFloat = 0; var estimated = false; var markdown: MarkdownLayout? = nil }
    private var store: [Key: Value] = [:]
    /// Streaming bubbles (ask 11): every chunk is a new text under one id; only their latest measurements are kept
    /// (at most 16), never in `store` or `latest` (they grew by one text layout per chunk).
    private var streamStore: [Key: Value] = [:]
    /// The latest exact measurement of each part at any width (estimates).
    private var latest: [PartKey: Value] = [:]
    private let lock = NSLock()
    private(set) var hits = 0, misses = 0, estimates = 0, reuses = 0

    /// A part whose content changes in place is a new measurement: text a host
    /// replaces under the same message id (an optimistic send, then the stored
    /// message), a link preview's metadata (title, site, image), an
    /// attachment's dimensions. The key used to be the message id and its edit
    /// count only: the bubble kept the size of the first text while the row
    /// drew the new one (cmux-next: a one-line bubble under a two-line text, the
    /// second line outside it), and a card kept the domain card's size while
    /// it drew the image (its text below the card).
    static func partVersion(_ p: Part) -> Int {
        var h = Hasher()
        switch p {
        case let .text(t, runs): h.combine(t); h.combine(runs.count); for r in runs { h.combine(r.start); h.combine(r.length); h.combine(r.style) }
        case let .link(url, title, site, image, theme): h.combine(url); h.combine(title); h.combine(site); h.combine(image); h.combine(theme)
        case let .attachment(a): h.combine(a.kind); h.combine(a.asset); h.combine(a.poster); h.combine(a.width); h.combine(a.height)
            h.combine(a.fileName); h.combine(a.byteSize); h.combine(a.mimeType) // cmux: a file card's width follows its text (#26395)
        default: return 0
        }
        return h.finalize()
    }

    /// One exact measurement (Core Text or the markdown layout), no cache.
    private static func measure(_ m: Message, _ part: Part, width: CGFloat, scale: CGFloat) -> Value {
        if case let .text(t, _) = part, let md = Markdown.layout(t, message: m.id, format: m.format, width: width) {
            return Value(size: md.size, text: md.proxy, width: width, markdown: md)
        }
        let (size, tl) = Sizing.size(of: part, width: width, scale: scale)
        return Value(size: size, text: tl, width: width)
    }

    static func version(_ m: Message) -> Int { ((m.edits?.count ?? 0) * 2 + (m.retractedAt == nil ? 0 : 1)) * 2 + (m.deletedAt == nil ? 0 : 1) }

    /// The part's size at `width`. With `estimate`, a miss does not run Core
    /// Text: it scales a measurement taken at another width (no text layout;
    /// the row is re-measured before it draws). Exact misses measure now.
    func size(_ m: Message, _ pi: Int, width: CGFloat, estimate: Bool = false, scale: CGFloat = Fixture.renderScale) -> Value {
        // a part index from another version of the message measures nothing (no trap).
        guard let part = m.parts[checked: pi] else { return Value(size: .zero, text: nil, width: width) }
        // Long text: blocks, estimated then measured near the viewport (LongText.swift); never hashed or cached here.
        if case let .text(t, _) = part, LongText.isLong(t) { // checked part
            return Value(size: LongTextStore.shared.size(t, width: width, message: m.id, markdown: m.isMarkdown, scale: scale), text: nil, width: width)
        }
        // Custom rows: their own cache, estimates for main-only providers (CustomRows.swift).
        if case let .custom(c) = part {
            let (s, tl, est) = CustomRows.measure(c, message: m.id, part: pi, width: width)
            return Value(size: s, text: tl, width: width, estimated: est)
        }
        let version = MeasureCache.version(m) &+ MeasureCache.partVersion(part) &+ Markdown.versionSalt(m.id)
        let k = Key(id: m.id, part: pi, version: version, width: width, markdown: m.isMarkdown, scale: scale)
        let pk = PartKey(id: m.id, part: pi, version: version, markdown: m.isMarkdown, scale: scale)
        let streaming = StreamBubble.isStream(m.id)
        lock.lock()
        if let v = streaming ? streamStore[k] : store[k] { hits += 1; lock.unlock(); return v }
        if streaming {
            misses += 1
            lock.unlock()
            let v = MeasureCache.measure(m, part, width: width, scale: scale)
            lock.lock()
            if streamStore.count >= 16 { streamStore.removeAll() }
            streamStore.updateValue(v, forKey: k)
            lock.unlock()
            return v
        }
        // Plain text that no width wrapped and that fits the new column: the same lines at the new
        // width, exact (no Core Text, no estimate). A divider drag or live resize changes most
        // short bubbles' widths only in this way.
        if let old = latest[pk], let v = MeasureCache.sameLayout(old, at: width, part: part, scale: scale) { // the checked part
            reuses += 1
            store[k] = v
            lock.unlock()
            return v
        }
        if estimate, let old = latest[pk] {
            estimates += 1
            lock.unlock()
            return MeasureCache.scale(old, to: width, part: part, scale: scale)
        }
        misses += 1
        lock.unlock()
        let v = MeasureCache.measure(m, part, width: width, scale: scale)
        lock.lock()
        store.updateValue(v, forKey: k) // dictionary writes
        latest.updateValue(v, forKey: pk)
        lock.unlock()
        return v
    }

    /// Text keeps its total line length: lines = ceil(sum of line widths / new column).
    /// `v` (an exact measurement at another width) at `width` when Core Text would lay the part out
    /// the same way: a plain text part (no markdown) whose every line ends at a hard newline or the
    /// end of the text (no soft wrap) and whose widest line fits the new column. CTTypesetter breaks
    /// a paragraph only where it does not fit, so each paragraph is one line again; the bubble size
    /// follows from the lines alone (Sizing.size). Nil otherwise.
    /// Also a narrower column (live resize, a divider drag: cx-3cb resize-drops2) whose every line still fits
    /// it without its trailing whitespace (`Line.fit`): CTTypesetter's break is greedy, each line was the
    /// longest that fit the wider column, so the word after it does not fit the narrower one either, and
    /// each line is the same again; the bubble width follows the new column (Sizing.size: a wrapped line's
    /// trailing space can reach past it). A line within 0.01 pt of the column is measured again (Core Text's
    /// own fit test may sum the widths differently from the cut line's).
    static func sameLayout(_ v: Value, at width: CGFloat, part: Part, scale: CGFloat = Fixture.renderScale) -> Value? {
        guard v.markdown == nil, !v.estimated, let tl = v.text, case .text = part else { return nil }
        let col = Metrics(width: width).maxTextWidth
        if v.width > 0, col <= Metrics(width: v.width).maxTextWidth, tl.lines.allSatisfy({ $0.fit <= col - 0.01 }) {
            return Value(size: CGSize(width: Sizing.textBalloonWidth(tl.width, column: col, scale: scale), height: v.size.height), text: tl, width: width)
        }
        guard tl.width <= col else { return nil }
        let s = tl.text as NSString
        for l in tl.lines {
            let end = NSMaxRange(l.range)
            guard end >= s.length || s.character(at: end) == 0x0A else { return nil }
        }
        return Value(size: v.size, text: tl, width: width)
    }

    private static func scale(_ v: Value, to width: CGFloat, part: Part, scale: CGFloat) -> Value {
        if v.markdown != nil {
            // Markdown keeps its height until measured at the new width.
            let col = Metrics(width: width).maxTextWidth + 2 * Fixture.bubblePadX
            return Value(size: CGSize(width: min(v.size.width, col), height: v.size.height), text: nil, width: width, estimated: true)
        }
        guard let tl = v.text else {
            // Media and cards: same aspect, clamped to the new column.
            let (fresh, _) = Sizing.size(of: part, width: width, scale: scale)
            return Value(size: fresh, text: nil, width: width, estimated: true)
        }
        let col = Metrics(width: width).maxTextWidth
        let total = tl.lines.reduce(0) { $0 + $1.width }
        let lines = max(1, CrashGuard.int((total / col).rounded(.up), in: CrashGuard.countRange)) // no trap on NaN
        let w = Sizing.textBalloonWidth(max(tl.width, total / CGFloat(lines)), column: col, scale: scale)
        return Value(size: CGSize(width: w, height: CGFloat(lines) * Fixture.lineHeight + 2 * Fixture.bubblePadY),
                     text: nil, width: width, estimated: true)
    }

    /// Measure every part of `messages` at `width` (call off the main thread).
    /// `scale`: the view's (pass it from another queue: a task-local scope does not follow a block).
    func prefetch(_ messages: [Message], width: CGFloat, scale: CGFloat = Fixture.renderScale) {
        for m in messages { for pi in m.parts.indices { _ = size(m, pi, width: width, scale: scale) } }
    }
    /// `prefetch` on all cores (interleaved slices); returns when every message is measured.
    func prefetchParallel(_ messages: [Message], width: CGFloat, scale: CGFloat = Fixture.renderScale) {
        let n = min(messages.count / 4, ProcessInfo.processInfo.activeProcessorCount)
        guard n > 1 else { return prefetch(messages, width: width, scale: scale) }
        DispatchQueue.concurrentPerform(iterations: n) { k in
            for i in stride(from: k, to: messages.count, by: n) {
                // checked read (crash ratchet)
                guard let m = messages[checked: i] else { continue }
                for pi in m.parts.indices { _ = size(m, pi, width: width, scale: scale) }
            }
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }

    /// LRU-ish bound: drop measurements for messages outside the window.
    func trim(keeping ids: Set<ID>) {
        lock.lock()
        if store.count > 4 * ids.count + 2000 {
            store = store.filter { ids.contains($0.key.id) }
            latest = latest.filter { ids.contains($0.key.id) }
        }
        lock.unlock()
    }
}

/// Derives the transcript rows from state (MODEL.md "Derived").
enum RowBuilder {
    static let groupGap: TimeInterval = 60
    /// A time label above a message more than an hour after the one above it on macOS 27 (AX walk of the real
    /// transcript, macOS 27.0.1, 2026-10-14: no label in 29 of 29 pairs 11 to 57 min apart, a label in 21 of 22
    /// pairs 72 min or more apart, one 5 h pair without one UNEXPLAINED; 60 min is UNVERIFIED between 57 and 72
    /// min), more than 15 min on macOS 26 (the original
    /// recording, macOS 26: "Today 12:06 PM" over "hello world" 21 min after the message above) (cx-3cb row-gap).
    static var separatorGap: TimeInterval { ComposeMetrics.macOS26 ? 15 * 60 : 60 * 60 }

    /// `previousRow`: the kind of the row just above `range` (gaps depend on it).
    /// `width`: layout width (captured on main). `exact`: message indices to
    /// measure exactly; others may use estimates (nil: all exact).
    static func rows(_ s: AppState, messages loaded: [Message], now: Date, threadMode: Bool = false, range: Range<Int>? = nil,
                     previousRow: RowSpec.Kind? = nil, width: CGFloat = Metrics.current.width, exact: Range<Int>? = nil,
                     scale: CGFloat = Fixture.renderScale, threadCounts: [ID: Int]? = nil) -> [RowSpec] {
        let me = s.me
        // cmux: a group chat names and draws the avatar of another person's runs (iMessage; `Conversation.cmuxGroup`).
        let group = s.conversation.cmuxGroup == true
        var rows: [RowSpec] = []
        var span = (range ?? 0..<loaded.count).clamped(to: 0..<loaded.count) // a range from an older window stays inside
        // The host's streaming bubbles with text (ask 11, HostHooks.swift) follow the newest message as the messages
        // they will be: grouping, tails, gaps and receipts come out as they will with the final message. None: the
        // loaded messages as they are (no copy).
        let tail = !threadMode && span.upperBound == loaded.count && s.atNewest
        let writing = tail ? s.ui.streams.filter { !$0.parts.isEmpty } : []
        let messages = writing.isEmpty ? loaded : loaded + writing.map(\.message)
        if !writing.isEmpty { span = span.lowerBound..<messages.count }
        let receipts = receiptTargets(messages, me: me)
        // Thread counts (roots with 2+ replies get a label).
        var replyCount: [ID: Int] = [:]
        if !threadMode {
            for m in messages.slice(span.lowerBound, span.upperBound) { // no index math
                if let r = m.replyTo { replyCount.updateValue(0, forKey: r.messageId) } else { replyCount.updateValue(0, forKey: m.id) }
            }
            for m in s.conversation.messages {
                if let r = m.replyTo, m.retractedAt == nil, let c = replyCount[r.messageId] { replyCount[r.messageId] = c + 1 }
            }
            // ThreadMode.tree: every reply of a tree stores its root in `replyTo`, so the count above
            // is the root's whole subtree; the host's count wins when it gives one (Message.replyCount).
            if s.ui.threadMode == .tree {
                for m in s.conversation.messages where replyCount[m.id] != nil {
                    if let n = m.replyCount { replyCount[m.id] = max(0, n) }
                }
            }
        }
        // A message's thread: a reply's root, or the message itself when it has a reply that is not unsent or deleted
        // (inline under it, or elsewhere with "N Replies" or a preview at the reply). Messages separates a thread from
        // the messages around it: the gap above a root is 32 pt (macOS 27, lossless typing-unfocused-take1: root top
        // minus the bubble above 7.5 -> 30.0 pt while the first reply arrives; AX of the 18:00 scene: "Alpha.", whose
        // two replies are further down, 32 pt under my message; AX walk of the real transcript 2026-10-14, cx-3cb
        // row-gap: every gap above a root with replies is 32). A root whose replies are all unsent or deleted is not
        // a root. No thread view: one thread.
        var liveRoots: Set<ID> = []
        if !threadMode {
            for m in s.conversation.messages where m.retractedAt == nil && m.deletedAt == nil {
                if let r = m.replyTo { liveRoots.insert(r.messageId) }
            }
        }
        func thread(_ x: Message, at i: Int) -> ID? {
            if let r = x.replyTo { return r.messageId }
            return liveRoots.contains(x.id) ? x.id : nil
        }
        // The message above the range: the nearest one that is not deleted.
        var prevIndex = messages.prefix(max(0, span.lowerBound)).lastIndex { $0.deletedAt == nil } ?? -1
        var prev: Message? = messages.prefix(max(0, span.lowerBound)).last { $0.deletedAt == nil } // no index math
        for (idx, m) in zip(span, messages.dropFirst(span.lowerBound)) {
            if m.deletedAt != nil { continue }
            let next = messages.dropFirst(idx + 1).first { $0.deletedAt == nil }
            let outgoing = m.senderId == me
            var gap: CGFloat
            var connector: String?
            if prev.map({ m.date.timeIntervalSince($0.date) > separatorGap }) ?? true { // no force unwrap
                // The time label sits 17.5 pt under a thread reply and 13.5 pt under any other bubble, and the next
                // bubble 5 pt under the label (macOS 27, AX walk of the real transcript, 2026-10-14, cx-3cb row-gap:
                // 17.0 to 17.5 under 16 of 16 replies, 13.5 under 5 of 5 other messages, 5.0 below in 3 of 3). The
                // row is 4 pt shorter under a non-reply; its text keeps its place over the row's bottom (RowDrawing).
                let underReply = prev.map { $0.replyTo != nil } ?? true
                rows.append(RowSpec(key: "sep:\(m.id)", kind: .separator(bold: Format.day(m.date, now: now), rest: Format.time(m.date)),
                                    gap: prev == nil ? 12 : 0, height: underReply ? 35.5 : 31.5))
                gap = 0
            } else if let r = m.replyTo, let p = prev, p.id == r.messageId {
                // Measured: 2.5 pt right under the root bubble, 3.5 pt under a
                // label row, 4 pt under a receipt.
                let lastKind = rows.last?.kind ?? previousRow
                switch lastKind {
                // In a thread or reply view the root is its own group (tail) and the first
                // reply sits 8 pt under it (macOS 27, thread-open-esc reference).
                case .part: gap = threadMode ? 8 : 2.5
                case .receipt: gap = 4
                default: gap = 3.5
                }
                // My reply right under my own root draws no connector: Messages draws thread lines on the
                // incoming side only (outgoing-thread-reply-take4: my reply under the preview of my root
                // has no stub, and Instinct's replies take the line on the left). The mirrored arc ran
                // from the root's centre through my root's text (hq-6d, cmux Home, 2026-10-11).
                if !threadMode, !(outgoing && p.senderId == me) { connector = "part:\(r.messageId):\(r.partIndex)" }
            } else if case .replies = rows.last?.kind ?? previousRow {
                // Under a root's "N Replies" label the next bubble sits 8 pt under the label's text (3 pt under
                // our 22 pt label row), with or without a sender change, also when the thread ends there; another
                // root right under it sits 4 pt under the text (-1 pt) (macOS 27, AX walk of the real transcript,
                // 2026-10-14, cx-3cb row-gap: 7.5 to 8.0 in 30 of 30 pairs, 4.0 in 5 of 5 pairs root to root).
                let otherRoot = m.replyTo == nil && liveRoots.contains(m.id) && prev.map { thread($0, at: prevIndex) != m.id } ?? false
                gap = otherRoot ? -1 : 3
            } else if let p = prev, thread(p, at: prevIndex) != thread(m, at: idx) {
                // A change of thread, for either sender: 32 pt (macOS 27, AX walk of the real transcript
                // 2026-10-14, cx-3cb row-gap: 32.0 to 32.5 in 35 of 35 pairs across a thread boundary).
                gap = 32
            } else if let p = prev, p.senderId == m.senderId, m.date.timeIntervalSince(p.date) < groupGap {
                gap = 3      // measured 3 between parts of a group (text and media alike)
            } else if let p = prev, p.senderId == m.senderId, thread(m, at: idx) != nil {
                // The same sender a minute or more later inside one thread: 32 pt (AX walk: Instinct's two
                // replies to one root 95 s apart). UNVERIFIED beyond that one pair.
                gap = 32
            } else {
                // One thread (or none) and a new group: a sender change, or the same sender a minute or more
                // later outside threads: 8 pt (macOS 27; AX of the 18:00 scene: "The photo failed..." to my
                // "Round 3 ..." 52.5 -> 60.5 pt, 53 min apart; AX walk of the real transcript, 2026-10-14: 8.0
                // in 10 of 10 sender changes inside one thread or outside threads, 0 s to 53 min apart, and 2 of 2
                // same-sender pairs 98 s and 53 min apart; settled lossless stills: "Reply to Charlie
                // from the menu." to Instinct's reply in the same thread 482.0 -> 490.0 pt, bubble-stills
                // tp0000ms, and 795.0 -> 803.0 pt, send-typed tp8000ms). It was 32 for every sender change, 7
                // in one thread and 12 for the same sender a minute later (cx-3cb row-gap).
                gap = 8
            }
            // Under a receipt ("Delivered", "Read") the receipt row takes the place of the gap:
            // the next bubble sits 4 pt under it (body to body 20 pt), for a sender change too
            // (macOS 27, lossless send-typed and send-typed-media references; it was 16 + 32).
            if case .receipt = rows.last?.kind ?? previousRow, gap > 4 { gap = 4 }
            // A reply whose root is not directly above (and that does not
            // continue the same thread) gets a preview of the root.
            if let r = m.replyTo, !threadMode, connector == nil, let p = prev, p.id != r.messageId, p.replyTo != r {
                let root = s.conversation.messages.first { $0.id == r.messageId }
                let part = root.flatMap { r.partIndex < $0.parts.count ? $0.parts[r.partIndex] : nil }
                let pv = ThreadPreview.make(root: r, part: part, count: replyCount[r.messageId] ?? 0, outgoing: root?.senderId == me, width: width)
                // Under a root's "N Replies" label the preview sits 32 pt under the label's text, 5 pt less
                // under our label row (AX walk 2026-10-14: 32.0 in 11 of 11 label-to-preview pairs, cx-3cb row-gap).
                var pvGap = ThreadPreview.gap
                if case .replies = rows.last?.kind ?? previousRow { pvGap -= 5 }
                rows.append(RowSpec(key: "preview:\(m.id)", kind: .threadPreview(pv), gap: pvGap, height: pv.height(scale: scale)))
                gap = ThreadPreview.replyGap
            }

            if m.retractedAt != nil {
                rows.append(RowSpec(key: "unsent:\(m.id)", kind: .unsent(outgoing: outgoing), gap: max(gap, 8), height: 16))
            } else {
                // no force unwrap 
                let lastOfGroup = next.map { next in next.senderId != m.senderId || next.date.timeIntervalSince(m.date) >= groupGap
                    || next.retractedAt != nil || next.replyTo != m.replyTo
                    || thread(next, at: idx + 1) != thread(m, at: idx) } ?? true
                // cmux: a group chat's run of another person's messages (the rule of lastOfGroup, seen from the
                // message above): its first bubble gets the sender's name, its last their avatar, and every
                // incoming bubble moves right of the avatar column. A reply drawn with a thread connector
                // has no name row (the connector's stroke runs through it); its avatar names it.
                let inGroup = group && !outgoing
                let sender = inGroup ? s.conversation.participants.first { $0.id == m.senderId } : nil
                let startsRun = prev.map { p in p.senderId != m.senderId || m.date.timeIntervalSince(p.date) >= groupGap
                    || p.retractedAt != nil || m.replyTo != p.replyTo
                    || thread(m, at: idx) != thread(p, at: prevIndex) } ?? true
                if let name = sender?.displayName, !name.isEmpty, startsRun, connector == nil {
                    rows.append(RowSpec(key: "name:\(m.id)", kind: .senderName(name), gap: gap, height: 14))
                    gap = 1
                }
                for (pi, part) in m.parts.enumerated() {
                    // A streaming bubble (past the loaded messages) is always measured: it draws now.
                    let measured = MeasureCache.shared.size(m, pi, width: width, estimate: idx < loaded.count && (exact.map { !$0.contains(idx) } ?? false), scale: scale)
                    let (size, tl) = (measured.size, measured.text)
                    let reactions = m.reactions.filter { $0.partIndex == pi }
                    var g = pi == 0 ? gap : 3
                    // Link card then text: 3.5 pt (measured in the recording);
                    // every other pair in a group is 3 pt (macOS 26 references).
                    if g == 3, isText(part) {
                        let before: Part? = pi > 0 ? m.parts[checked: pi - 1] : (gap == 3 ? prev?.parts.last : nil)
                        if case .link = before { g = 3.5 }
                    }
                    if pi > 0, case .text = m.parts[checked: pi - 1], !isText(part) { g = 3 }
                    // A tapback badge: 27.5 pt over the part, and a sender change above it is 27 pt,
                    // not 32 (macOS 27, lossless takes: a heart on an incoming bubble in a group moves
                    // the rows above by 27.5 pt, tapback-menu-heart; one on my bubble under Instinct's,
                    // by 22.5 pt, send-typed; macOS 26 measured 10). AX walk 2026-10-14 (cx-3cb row-gap): a
                    // change of thread above a badge 54.5 to 55 pt bubble to bubble in 34 of 35 pairs (one 32), the same sender
                    // 30.5 to 31 in 3 of 3; a sender change in one thread (8 + 27.5) is UNVERIFIED (no pair).
                    if !reactions.isEmpty { g = (g >= 32 ? g - 5 : g) + 27.5 }
                    var failed = false
                    if case .failed = m.status { failed = true }
                    let row = PartRow(ref: PartRef(messageId: m.id, partIndex: pi), part: part, outgoing: CustomRows.outgoing(part, sender: outgoing),
                                      tail: lastOfGroup && pi == m.parts.count - 1, reactions: reactions,
                                      myReaction: reactions.firstIndex { $0.senderId == me }, failed: failed,
                                      size: size, text: tl, connectorRoot: pi == 0 ? connector : nil, markdown: measured.markdown,
                                      markdownFormat: m.isMarkdown,
                                      cmuxAvatar: inGroup && lastOfGroup && pi == m.parts.count - 1 && !isCustom(part) ? SenderAvatar(sender?.avatar) : nil,
                                      cmuxIndent: inGroup && !isCustom(part) ? SenderAvatar.bubbleInset : 0)
                    rows.append(RowSpec(key: "part:\(m.id):\(pi)", kind: .part(row), gap: g, height: size.height,
                                        width: width, estimated: measured.estimated))
                }
                if m.edits?.isEmpty == false {
                    rows.append(RowSpec(key: "edited:\(m.id)", kind: .label(text: Strings.edited, outgoing: outgoing, color: .link),
                                        gap: 1, height: 14))
                }
                if case .failed = m.status {
                    // cmux: "May Not Have Been Delivered" for a send that reached the owner unanswered.
                    rows.append(RowSpec(key: "failed:\(m.id)", kind: .label(text: CmuxStrings.failedLabel(m.status), outgoing: outgoing, color: .failure),
                                        gap: 1, height: 14))
                }
                if !threadMode, let n = replyCount[m.id], n >= 2, m.replyTo == nil {
                    rows.append(RowSpec(key: "replies:\(m.id)", kind: .replies(count: n, root: PartRef(messageId: m.id, partIndex: 0),
                                                                               outgoing: outgoing), gap: 0, height: 22))
                }
                // ThreadMode.tree thread view: "N Replies" under a reply that has replies opens its
                // branch (drill-in). `threadCounts` is nil in `.messages` mode and in the transcript.
                if threadMode, let n = threadCounts?[m.id], n >= 1 {
                    rows.append(RowSpec(key: "replies:\(m.id)", kind: .replies(count: n, root: PartRef(messageId: m.id, partIndex: 0),
                                                                               outgoing: outgoing), gap: 0, height: 22))
                }
                if let r = receipts[m.id] {
                    rows.append(RowSpec(key: "receipt:\(m.id)", kind: .receipt(bold: r.0, rest: r.1), gap: 0, height: 16))
                }
            }
            prev = m; prevIndex = idx
        }
        // cmux: the host's notice, centered like the date row, under the newest message. Row key "notice" (the
        // tail rows' paging rules); none while upstream's status line (ask 9, same key) is set.
        if !threadMode, span.upperBound == messages.count, s.atNewest, s.ui.notice?.isEmpty ?? true, let notice = s.ui.cmuxNotice {
            rows.append(RowSpec(key: "notice", kind: .separator(bold: "", rest: notice), gap: 0, height: 35.5))
        }
        // A stream with text is its sender's bubble (no typing indicator for them); one without text is the indicator.
        let typists = s.ui.typing.contains { t in t != me && !writing.contains { $0.sender == t } }
            || (tail && s.ui.streams.contains { $0.parts.isEmpty && $0.sender != me })
        // cmux: the host's status line (ask 9) goes above the typing indicator, not under it (upstream: last,
        // centered): the Chief's "working on" line reads as a caption of the bubble it heads (RowDraw `.notice`
        // draws it at the bubble's left edge). Same gap and height as upstream's.
        if !threadMode, span.upperBound == messages.count, s.atNewest, let notice = s.ui.notice, !notice.isEmpty {
            // cmux: one caption row per line (the running indicator's folded steps, narration and step: HomeNoticeRows).
            rows.append(RowSpec(key: "notice", kind: .notice(notice), gap: 8, height: HomeNoticeRows.height(notice)))
        }
        if !threadMode, span.upperBound == messages.count, s.atNewest, typists {
            rows.append(RowSpec(key: "typing", kind: .typing, gap: 0, height: 35))
        }
        rows = rows.map { var r = $0; r.width = width; return r } // no index writes
        return rows
    }

    /// `rows(s, messages: messages, ..., width: width, exact: exact)` from `derived`, the rows that
    /// the same call made at another width with the same state, time and strings. A width changes
    /// only the part rows' measurement (size, text layout, markdown, estimate) and every row's
    /// `width`, and a text root's preview (it wraps in the bubble column: made again from the row's
    /// own root, count and side); keys, gaps, separators and receipts do not depend on it. So a
    /// divider drag or live resize step re-measures the parts and skips the derivation (receipts,
    /// reply counts, thread previews, day labels) over the loaded window. Nil when a part row
    /// does not name a loaded message (the caller then derives).
    static func rewidth(_ derived: [RowSpec], messages: [Message], width: CGFloat, exact: Range<Int>?,
                        scale: CGFloat = Fixture.renderScale) -> [RowSpec]? {
        var out: [RowSpec] = []
        out.reserveCapacity(derived.count)
        var idx = 0
        // element-wise, no index math (crash ratchet): the same rows in the same order.
        for row in derived {
            var row = row
            row.width = width
            if case let .threadPreview(pv) = row.kind, pv.isText {
                let again = ThreadPreview.make(root: pv.root, part: pv.part, count: pv.count, outgoing: pv.outgoing, width: width)
                row.kind = .threadPreview(again)
                row.height = again.height(scale: scale)
            }
            guard case var .part(p) = row.kind else { out.append(row); continue }
            // Rows follow message order: the part's message is at or after the previous one.
            // (dropFirst(idx).first: past the end is the normal miss, not a fault.)
            while let m = messages.dropFirst(idx).first, m.id != p.ref.messageId { idx += 1 }
            guard let m = messages.dropFirst(idx).first, p.ref.partIndex < m.parts.count else { return nil }
            let measured = MeasureCache.shared.size(m, p.ref.partIndex, width: width,
                                                    estimate: exact.map { !$0.contains(idx) } ?? false, scale: scale)
            p.size = measured.size
            p.text = measured.text
            p.markdown = measured.markdown
            row.kind = .part(p)
            row.height = measured.size.height
            row.estimated = measured.estimated
            out.append(row)
        }
        return out
    }

    /// Rows that belong after the newest loaded message, always derived again with it: the typing indicator, the
    /// host's status line (ask 9) and the host's streaming bubbles (ask 11).
    static func isTrailing(_ key: String) -> Bool {
        key == "typing" || key == "notice" || owner(key).map(StreamBubble.isStream) == true
    }

    /// The message id of a row key ("kind:messageID[:part]"), without allocating.
    static func owner(_ key: String) -> Substring? {
        guard let a = key.firstIndex(of: ":") else { return nil }
        let rest = key.suffix(from: key.index(after: a)) // no range subscripts
        return rest.firstIndex(of: ":").map { rest.prefix(upTo: $0) } ?? rest
    }

    /// Whether a row key belongs to a message (keys are "kind:messageID[:part]").
    static func key(_ key: String, belongsTo id: ID) -> Bool {
        let parts = key.split(separator: ":", maxSplits: 2)
        return parts.count >= 2 && parts[1] == id
    }

    private static func isText(_ p: Part?) -> Bool { if case .text = p { return true } else { return false } }
    /// cmux: a custom part keeps its own layout (a full-width row spans the transcript): no group avatar column.
    private static func isCustom(_ p: Part) -> Bool { if case .custom = p { return true } else { return false } }

    /// "Read <time>" under my latest read message; "Delivered" under my
    /// latest delivered message when it is newer.
    static func receiptTargets(_ messages: [Message], me: ID) -> [ID: (String, String)] {
        var lastRead: (Int, Message, String)?
        var lastDelivered: (Int, Message)?
        // From the newest message back to my newest read one (a delivered one older than it
        // shows nothing): O(tail), not O(loaded window), per derive.
        scan: for (i, m) in zip(messages.indices.reversed(), messages.reversed()) { // no index math (lazy, still O(tail))
            if m.senderId == me && m.retractedAt == nil && m.deletedAt == nil {
                switch m.status {
                case let .read(at): lastRead = (i, m, at); break scan
                case .delivered: if lastDelivered == nil { lastDelivered = (i, m) }
                default: break
                }
            }
        }
        var out: [ID: (String, String)] = [:]
        if let r = lastRead { out.updateValue((Strings.read, "\u{00A0}" + Format.time(Instant.parse(r.2))), forKey: r.1.id) }
        if let d = lastDelivered, d.0 > (lastRead?.0 ?? -1) { out.updateValue((Strings.delivered, ""), forKey: d.1.id) }
        return out
    }
}

enum Format {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Instant.locale
        f.timeZone = Instant.zone
        f.dateFormat = "h:mm\u{202F}a"
        return f
    }()
    private static var timeMemo: [Date: String] = [:]
    private static let timeLock = NSLock()
    /// Memoized (receipt rows format the same times on every derive; ICU costs 0.1-0.3 ms per call).
    static func time(_ d: Date) -> String {
        timeLock.lock()
        if let s = timeMemo[d] { timeLock.unlock(); return s }
        timeLock.unlock()
        let s = timeFormatter.string(from: d)
        timeLock.lock(); if timeMemo.count > 4096 { timeMemo.removeAll() }; timeMemo[d] = s; timeLock.unlock()
        return s
    }
    private static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = Instant.zone; return c }()
    private static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Instant.locale
        d.timeZone = Instant.zone
        d.dateFormat = f
        return d
    }
    private static let weekday = formatter("EEEE")
    private static let monthDay = formatter("MMM d")
    private static let monthDayYear = formatter("MMM d, yyyy")
    /// `day` per date for the day `now` is in: a width change derives every separator row
    /// again (Calendar work was about 1 % of main in a divider drag). Thread safe.
    private static let dayLock = NSLock()
    private static var dayMemo: [Date: String] = [:]
    private static var dayMemoToday: DateInterval?
    private static var dayMemoBundle: ObjectIdentifier?
    /// The calendar day of `now` (day labels depend on `now` only through it).
    static func dayInterval(_ now: Date) -> DateInterval? { calendar.dateInterval(of: .day, for: now) }
    static func day(_ d: Date, now: Date) -> String {
        let bundle = ObjectIdentifier(MessagesLabLocalization.bundle)
        dayLock.lock()
        if dayMemoBundle == bundle, let today = dayMemoToday, now >= today.start, now < today.end, let s = dayMemo[d] { dayLock.unlock(); return s }
        dayLock.unlock()
        let s = dayUncached(d, now: now)
        let today = calendar.dateInterval(of: .day, for: now)
        dayLock.lock()
        if dayMemoToday != today || dayMemoBundle != bundle { dayMemo.removeAll(); dayMemoToday = today; dayMemoBundle = bundle }
        if dayMemo.count < 4096 { dayMemo[d] = s }
        dayLock.unlock()
        return s
    }
    private static func dayUncached(_ d: Date, now: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return Strings.today }
        if days == 1 { return Strings.yesterday }
        if days < 7 { return weekday.string(from: d) }
        return days < 300 ? monthDay.string(from: d) : monthDayYear.string(from: d)
    }
    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
    static func duration(_ s: Double) -> String { let t = CrashGuard.int(s); return String(format: "%d:%02d", t / 60, t % 60) } // no trap on NaN
}

/// Where every user-facing string of the MessagesLab code comes from (catalyst/Sources and
/// appkit-native/Sources, which cmux-next vendors). One injectable bundle for all catalogs:
/// `Localizable` (catalyst/Resources), `AppKitNative` and `SidebarLocalizable`
/// (appkit-native/Resources). A host copies those .xcstrings into its resources and sets
/// `bundle` (a Swift package: `Bundle.module`). Default: the bundle that contains this code,
/// not `Bundle.main` (in a host app they differ, and Bundle.main has no MessagesLab catalog).
/// `String(localized:)` without a bundle reads Bundle.main, so the code never uses it.
enum MessagesLabLocalization {
    private final class Token {}
    private static let lock = NSLock()
    // cmux: the package's bundle (Bundle(for:) of a class in a linked package is the app's).
    private static var current = Bundle.module
    static var bundle: Bundle {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    /// The string for `key` in the user's preferred language (of `bundle`); `english` when the
    /// catalog has no entry. `table`: nil is `Localizable`.
    static func string(_ key: String, _ english: String, table: String? = nil) -> String {
        bundle.localizedString(forKey: key, value: english, table: table)
    }
}

enum Strings {
    static var today: String { MessagesLabLocalization.string("separator.today", "Today") }
    static var yesterday: String { MessagesLabLocalization.string("separator.yesterday", "Yesterday") }
    static var read: String { MessagesLabLocalization.string("receipt.read", "Read") }
    static var delivered: String { MessagesLabLocalization.string("receipt.delivered", "Delivered") }
    static var edited: String { MessagesLabLocalization.string("label.edited", "Edited") }
    static var notDelivered: String { MessagesLabLocalization.string("label.notDelivered", "Not Delivered") }
    static var unsentMine: String { MessagesLabLocalization.string("row.unsent.mine", "You unsent a message") }
    static var unsentTheirs: String { MessagesLabLocalization.string("row.unsent.theirs", "A message was unsent") }
    static func replies(_ n: Int) -> String {
        // One reply: only a `.tree` thread view's drill-in label shows it (Messages labels 2 or more).
        if n == 1 { return MessagesLabLocalization.string("label.replies.one", "1 Reply") }
        return String(format: MessagesLabLocalization.string("label.replies", "%lld Replies"), n)
    }
    /// The `.tree` thread view's back control (cmux only).
    static var threadBack: String { MessagesLabLocalization.string("thread.back", "Back") }
    /// The host thread header's status chip and owner placeholder (cmux only).
    static var threadOpen: String { MessagesLabLocalization.string("thread.status.open", "Open") }
    static var threadResolved: String { MessagesLabLocalization.string("thread.status.resolved", "Resolved") }
    static var threadUnassigned: String { MessagesLabLocalization.string("thread.owner.none", "Unassigned") }
    static var location: String { MessagesLabLocalization.string("preview.location", "Location") }
    static func fileKind(_ a: Attachment) -> String {
        switch (a.fileName as NSString).pathExtension.lowercased() {
        case "pdf": return MessagesLabLocalization.string("file.kind.pdf", "PDF Document")
        case "zip": return MessagesLabLocalization.string("file.kind.zip", "ZIP Archive")
        case "m4a", "mp3", "wav", "aac": return MessagesLabLocalization.string("file.kind.audio", "Audio Recording")
        default: return MessagesLabLocalization.string("file.kind.document", "Document")
        }
    }
    // cmux: not "iMessage" (Apple's service name).
    static var placeholder: String { MessagesLabLocalization.string("compose.placeholder", "Message") }
    static var replyPlaceholder: String { MessagesLabLocalization.string("compose.placeholder.reply", "Reply") }
    static var menuReply: String { MessagesLabLocalization.string("menu.reply", "Reply") }
    static var menuCopy: String { MessagesLabLocalization.string("menu.copy", "Copy") }
    static var menuEdit: String { MessagesLabLocalization.string("menu.edit", "Edit") }
    /// cmux-only (Messages has no message links): the host's Copy Link (HostHooks.copyLink).
    static var menuCopyLink: String { MessagesLabLocalization.string("menu.copyLink", "Copy Link") }
    static var menuUndoSend: String { MessagesLabLocalization.string("menu.undoSend", "Undo Send") }
    static var menuReplyEllipsis: String { MessagesLabLocalization.string("menu.replyEllipsis", "Reply…") }
    static var menuTapbackDetails: String { MessagesLabLocalization.string("menu.tapbackDetails", "Tapback Details…") }
    static var menuAttachSticker: String { MessagesLabLocalization.string("menu.attachSticker", "Attach Sticker…") }
    static var menuShare: String { MessagesLabLocalization.string("menu.share", "Share…") }
    static var menuDelete: String { MessagesLabLocalization.string("menu.delete", "Delete…") }
    static var tapbackDetailsTitle: String { MessagesLabLocalization.string("tapback.details.title", "Tapbacks") }
    static var tapbackDetailsNone: String { MessagesLabLocalization.string("tapback.details.none", "No Tapbacks") }
    static var deleteConfirmTitle: String { MessagesLabLocalization.string("delete.confirm.title", "Delete this message?") }
    static var deleteConfirmInfo: String { MessagesLabLocalization.string("delete.confirm.info", "It is deleted from this Mac.") }
    static var deleteConfirmButton: String { MessagesLabLocalization.string("delete.confirm.button", "Delete") }
    static var deleteConfirmCancel: String { MessagesLabLocalization.string("delete.confirm.cancel", "Cancel") }
    static var menuTapback: String { MessagesLabLocalization.string("menu.tapback", "Tapback") }
    static func tapbackName(_ t: String) -> String {
        switch t {
        case "love": return MessagesLabLocalization.string("tapback.love", "Love")
        case "like": return MessagesLabLocalization.string("tapback.like", "Like")
        case "dislike": return MessagesLabLocalization.string("tapback.dislike", "Dislike")
        case "laugh": return MessagesLabLocalization.string("tapback.laugh", "Laugh")
        case "emphasize": return MessagesLabLocalization.string("tapback.emphasize", "Emphasize")
        default: return MessagesLabLocalization.string("tapback.question", "Question")
        }
    }
    static var laughGlyph: String { MessagesLabLocalization.string("tapback.laugh.glyph", "HA\nHA") }
}

extension CGSize: @retroactive Hashable {
    public func hash(into h: inout Hasher) { h.combine(width); h.combine(height) }
}
