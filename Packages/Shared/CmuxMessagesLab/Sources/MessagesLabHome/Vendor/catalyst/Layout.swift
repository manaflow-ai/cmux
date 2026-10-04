#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Text measured and wrapped with Core Text, the way the bubbles draw it.
struct TextLayout: Hashable {
    struct Line: Hashable { var range: NSRange; var width: CGFloat }
    var text: String
    var runs: [TextRun]
    var lines: [Line]
    /// Widest line including a wrapped line's trailing space (measured rule).
    var width: CGFloat

    static func make(_ text: String, runs: [TextRun], maxWidth: CGFloat, font: UIFont = Fixture.bodyFont) -> TextLayout {
        let attr = NSAttributedString(string: text, attributes: [.font: font])
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
            let line = CTTypesetterCreateLine(ts, CFRange(location: range.location, length: range.length))
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            lines.append(Line(range: range, width: w))
            start += n
            if start == len && s.hasSuffix("\n") { lines.append(Line(range: NSRange(location: len, length: 0), width: 0)) }
        }
        if lines.isEmpty { lines = [Line(range: NSRange(location: 0, length: 0), width: 0)] }
        return TextLayout(text: text, runs: runs, lines: lines, width: lines.map(\.width).max() ?? 0)
    }

    /// Attributed text for drawing (styles, links, mentions, detected data).
    func attributed(color: UIColor, linkColor: UIColor, kern: CGFloat = Fixture.bodyKern) -> NSAttributedString {
        let a = NSMutableAttributedString(string: text, attributes: [.font: Fixture.bodyFont, .foregroundColor: color, .kern: kern])
        for r in runs {
            let range = NSRange(location: r.start, length: r.length)
            guard NSMaxRange(range) <= a.length else { continue }
            var traits: UIFontDescriptor.SymbolicTraits = []
            for s in r.style ?? [] {
                switch s {
                case "bold": traits.insert(.traitBold)
                case "italic": traits.insert(.traitItalic)
                case "underline": a.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                case "strikethrough": a.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                default: break
                }
            }
            if r.mention != nil { traits.insert(.traitBold) }
            if !traits.isEmpty, let d = Fixture.bodyFont.fontDescriptor.withSymbolicTraits(traits) {
                a.addAttribute(.font, value: UIFont(descriptor: d, size: Fixture.bodyFont.pointSize), range: range)
            }
            if r.link != nil {
                a.addAttributes([.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
            if r.detected != nil { a.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        return a
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
        for j in 1..<max(1, i + 1) where j < lines.count {
            let loc = lines[j].range.location
            let hard = loc > 0 && loc <= ns.length && ns.character(at: loc - 1) == 10
            y += hard ? hardAdvance : Fixture.lineHeight
        }
        return y
    }
    func textHeight(hard: CGFloat) -> CGFloat { lineOffset(lines.count - 1, hard: hard) + Fixture.lineHeight }

    /// The link at a point relative to the text origin (first line top).
    func link(at p: CGPoint) -> String? {
        let i = Int(floor(p.y / Fixture.lineHeight))
        guard i >= 0, i < lines.count else { return nil }
        let attr = attributed(color: .white, linkColor: .white)
        let line = CTLineCreateWithAttributedString(attr.attributedSubstring(from: lines[i].range))
        let idx = CTLineGetStringIndexForPosition(line, CGPoint(x: p.x, y: 0)) + lines[i].range.location
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
    var maxTextWidth: CGFloat { (Fixture.maxTextWidth * width / Fixture.windowWidth * 10).rounded() / 10 }
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
        /// A copy of a thread's root above a reply whose root is not directly
        /// above it (macOS 26): a mini card or thumbnail, a short stub, and
        /// "N Replies" when the thread has 2 or more replies.
        case threadPreview(ThreadPreview)
    }
    enum LabelColor: Hashable { case secondary, failure, link }
}

struct ThreadPreview: Hashable {
    var root: PartRef
    /// The root part, when it is loaded (else a generic preview).
    var part: Part?
    var count: Int
    /// Measured layout (points, relative to the row's content top).
    var box: CGSize
    static let stubGap: CGFloat = 3.5, stubHeight: CGFloat = 12.5
    /// Space between the stub and the reply below.
    static let replyGap: CGFloat = 7
    /// Body bottom of the row above to the preview's top (measured 31.5).
    static let gap: CGFloat = 31.5
    var isThumbnail: Bool {
        if case let .attachment(a) = part, a.kind == "image" || a.kind == "video" { return true }
        return false
    }
    /// Measured on 2x screenshots of macOS 26 Messages: link/text card
    /// 180.5 x 48.5 (text 39 pt in, 15 pt right padding); photo thumbnail
    /// 48 pt wide at the photo's aspect.
    static func make(root: PartRef, part: Part?, count: Int) -> ThreadPreview {
        var p = ThreadPreview(root: root, part: part, count: count, box: .zero)
        if p.isThumbnail, case let .attachment(a) = part {
            p.box = CGSize(width: 48, height: (48 * CGFloat(a.height ?? 450) / CGFloat(max(1, a.width ?? 600))).rounded())
        } else {
            let (title, sub) = p.lines
            let w = max(TextDraw.width(title, font: ThreadPreview.titleFont), TextDraw.width(sub, font: ThreadPreview.subFont))
            p.box = CGSize(width: min(300, (39 + w + 15).rounded()), height: 48.5)
        }
        return p
    }
    static let titleFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
    static let subFont = UIFont.systemFont(ofSize: 12)
    /// Title and second line of the card.
    var lines: (String, String) {
        switch part {
        case let .link(url, title, site, _, _): return (title ?? site ?? url, site ?? url)
        case let .text(t, _):
            let one = t.replacingOccurrences(of: "\n", with: " ")
            return (String(one.prefix(28)), one.count > 28 ? String(one.dropFirst(28).prefix(30)) : "")
        case let .attachment(a): return (a.fileName, Format.bytes(a.byteSize))
        case let .location(_, _, title, _): return (title ?? Strings.location, "")
        case nil: return ("…", "")
        }
    }
    /// Row content height: box, stub.
    /// Box to stub: 3.5 pt under a card, 5.5 pt under a thumbnail (its tail is between).
    var stubGap: CGFloat { isThumbnail ? 5.5 : ThreadPreview.stubGap }
    var stubHeight: CGFloat { isThumbnail ? 11.5 : ThreadPreview.stubHeight }
    var height: CGFloat { box.height + stubGap + stubHeight }
}

struct PartRow: Hashable {
    var ref: PartRef
    var part: Part
    var outgoing: Bool
    var tail: Bool
    var reactions: [Reaction]
    var failed: Bool
    var size: CGSize
    var text: TextLayout?
    /// Key of the root row when this row draws a thread connector.
    var connectorRoot: String?
    /// The drawn body: lines after a hard newline are 15.5 pt apart, so the
    /// body is shorter than its 16 pt-per-line slot and sits at the slot top
    /// (measured on the sent 3-line bubble: top matches, bottom 1 pt higher).
    var bodySize: CGSize {
        guard let text else { return size }
        guard outgoing else { return size }
        return CGSize(width: size.width, height: min(size.height, text.textHeight(hard: TextLayout.hardBreakAdvance) + 2 * Fixture.bubblePadY))
    }
}

enum Sizing {
    static func size(of part: Part, width: CGFloat) -> (CGSize, TextLayout?) {
        let m = Metrics(width: width)
        let maxTextWidth = m.maxTextWidth, mediaWidth = m.mediaWidth
        switch part {
        case let .text(t, runs):
            let tl = TextLayout.make(t, runs: runs, maxWidth: maxTextWidth)
            let w = min(tl.width, maxTextWidth) + 2 * Fixture.bubblePadX
            return (CGSize(width: w, height: CGFloat(tl.lines.count) * Fixture.lineHeight + 2 * Fixture.bubblePadY), tl)
        case let .link(_, title, _, image, _):
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
                if let ref = a.kind == "video" ? (a.poster ?? a.asset) : a.asset, let img = Images.load(ref) {
                    let srcW = img.size.width * Images.assetScale
                    if srcW < pw { ph = ph * srcW / pw; pw = srcW }
                }
                let w = min(max(mediaWidth, min(300, m.maxTextWidth + 2 * Fixture.bubblePadX)), pw / 2)
                return (CGSize(width: w, height: min(360, (w * ph / pw).rounded())), nil)
            case "voiceMemo": return (CGSize(width: 196, height: 36), nil)
            case "contact": return (CGSize(width: 250, height: 56), nil)
            // File and audio rows (measured): 275 x 89.5, icon centred.
            default: return (CGSize(width: 275, height: 89.5), nil)
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
        }
    }

    /// Link previews: the image at its 2x point size, width capped at 350.
    static func linkImageSize(_ image: String?, maxWidth: CGFloat = Fixture.maxLinkWidth) -> (CGFloat, CGFloat) {
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
    private static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()
    /// Assets are 2x bitmaps (their point size is pixels / 2). An asset with
    /// a vector sibling (`name.svg`, see `VectorAsset`) is drawn from the
    /// vector at the current render scale instead, at the same point size.
    /// Thread safe; decoded once per scale (prefetch warms it).
    static func load(_ ref: String) -> UIImage? {
        let scale = Fixture.renderScale
        let key = ref + "@" + String(describing: scale)
        lock.lock()
        if let c = cache[key] { lock.unlock(); return c }
        lock.unlock()
        if let v = VectorAsset.image(for: ref, scale: scale) {
            lock.lock(); cache[key] = v; lock.unlock()
            return v
        }
        guard let data = try? Data(contentsOf: Fixtures.assetURL(ref)), let raw = UIImage(data: data),
              let cg = raw.cgImage else { return nil }
        let s = Images.assetScale
        let img = UIImage(cgImage: cg, scale: s, orientation: .up).preparingForDisplay() ?? UIImage(cgImage: cg, scale: s, orientation: .up)
        lock.lock(); cache[key] = img; lock.unlock()
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
        let rest = tag[r.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    private static func color(_ hex: String?) -> UIColor {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return .black }
        return UIColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    static func parse(_ text: String) -> (CGSize, [(CGPath, UIColor)])? {
        guard let svg = text.range(of: "<svg").map({ String(text[$0.lowerBound...].prefix(while: { $0 != ">" })) }),
              let w = attr(svg, "width").flatMap(Double.init), let h = attr(svg, "height").flatMap(Double.init) else { return nil }
        var shapes: [(CGPath, UIColor)] = []
        var rest = Substring(text)
        while let r = rest.range(of: "<") {
            let tag = String(rest[r.lowerBound...].prefix(while: { $0 != ">" }))
            rest = rest[r.upperBound...]
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
                var i = 0
                while i + 5 < nums.count {
                    p.addCurve(to: CGPoint(x: nums[i + 4], y: nums[i + 5]), control1: CGPoint(x: nums[i], y: nums[i + 1]),
                               control2: CGPoint(x: nums[i + 2], y: nums[i + 3]))
                    i += 6
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
    struct Key: Hashable { var id: ID; var part: Int; var version: Int; var width: CGFloat }
    struct PartKey: Hashable { var id: ID; var part: Int; var version: Int }
    struct Value { var size: CGSize; var text: TextLayout?; var width: CGFloat = 0; var estimated = false }
    private var store: [Key: Value] = [:]
    /// The latest exact measurement of each part at any width (estimates).
    private var latest: [PartKey: Value] = [:]
    private let lock = NSLock()
    private(set) var hits = 0, misses = 0, estimates = 0

    static func version(_ m: Message) -> Int { (m.edits?.count ?? 0) * 2 + (m.retractedAt == nil ? 0 : 1) }

    /// The part's size at `width`. With `estimate`, a miss does not run Core
    /// Text: it scales a measurement taken at another width (no text layout;
    /// the row is re-measured before it draws). Exact misses measure now.
    func size(_ m: Message, _ pi: Int, width: CGFloat, estimate: Bool = false) -> Value {
        let version = MeasureCache.version(m)
        let k = Key(id: m.id, part: pi, version: version, width: width)
        lock.lock()
        if let v = store[k] { hits += 1; lock.unlock(); return v }
        if estimate, let old = latest[PartKey(id: m.id, part: pi, version: version)] {
            estimates += 1
            lock.unlock()
            return MeasureCache.scale(old, to: width, part: m.parts[pi])
        }
        misses += 1
        lock.unlock()
        let (size, tl) = Sizing.size(of: m.parts[pi], width: width)
        let v = Value(size: size, text: tl, width: width)
        lock.lock()
        store[k] = v
        latest[PartKey(id: m.id, part: pi, version: version)] = v
        lock.unlock()
        return v
    }

    /// Text keeps its total line length: lines = ceil(sum of line widths / new column).
    private static func scale(_ v: Value, to width: CGFloat, part: Part) -> Value {
        guard let tl = v.text else {
            // Media and cards: same aspect, clamped to the new column.
            let (fresh, _) = Sizing.size(of: part, width: width)
            return Value(size: fresh, text: nil, width: width, estimated: true)
        }
        let col = Metrics(width: width).maxTextWidth
        let total = tl.lines.reduce(0) { $0 + $1.width }
        let lines = max(1, Int((total / col).rounded(.up)))
        let w = min(col, max(tl.width, total / CGFloat(lines))) + 2 * Fixture.bubblePadX
        return Value(size: CGSize(width: w, height: CGFloat(lines) * Fixture.lineHeight + 2 * Fixture.bubblePadY),
                     text: nil, width: width, estimated: true)
    }

    /// Measure every part of `messages` at `width` (call off the main thread).
    func prefetch(_ messages: [Message], width: CGFloat) {
        for m in messages { for pi in m.parts.indices { _ = size(m, pi, width: width) } }
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
    static let separatorGap: TimeInterval = 15 * 60

    /// `previousRow`: the kind of the row just above `range` (gaps depend on it).
    /// `width`: layout width (captured on main). `exact`: message indices to
    /// measure exactly; others may use estimates (nil: all exact).
    static func rows(_ s: AppState, messages: [Message], now: Date, threadMode: Bool = false, range: Range<Int>? = nil,
                     previousRow: RowSpec.Kind? = nil, width: CGFloat = Metrics.current.width, exact: Range<Int>? = nil) -> [RowSpec] {
        let me = s.me
        var rows: [RowSpec] = []
        let receipts = receiptTargets(messages, me: me)
        // Thread counts (roots with 2+ replies get a label).
        let span = range ?? 0..<messages.count
        var replyCount: [ID: Int] = [:]
        if !threadMode {
            for idx in span {
                if let r = messages[idx].replyTo { replyCount[r.messageId] = 0 } else { replyCount[messages[idx].id] = 0 }
            }
            for m in s.conversation.messages {
                if let r = m.replyTo, m.retractedAt == nil, let c = replyCount[r.messageId] { replyCount[r.messageId] = c + 1 }
            }
        }
        var prev: Message? = span.lowerBound > 0 ? messages[span.lowerBound - 1] : nil
        for idx in span {
            let m = messages[idx]
            let next = idx + 1 < messages.count ? messages[idx + 1] : nil
            let outgoing = m.senderId == me
            var gap: CGFloat
            var connector: String?
            if prev == nil || m.date.timeIntervalSince(prev!.date) > separatorGap {
                rows.append(RowSpec(key: "sep:\(m.id)", kind: .separator(bold: Format.day(m.date, now: now), rest: Format.time(m.date)),
                                    gap: prev == nil ? 12 : 0, height: 35.5))
                gap = 0
            } else if let r = m.replyTo, let p = prev, p.id == r.messageId {
                // Measured: 2.5 pt right under the root bubble, 3.5 pt under a
                // label row, 4 pt under a receipt.
                let lastKind = rows.last?.kind ?? previousRow
                switch lastKind {
                case .part: gap = 2.5
                case .receipt: gap = 4
                default: gap = 3.5
                }
                if !threadMode { connector = "part:\(r.messageId):\(r.partIndex)" }
            } else if let p = prev, p.senderId == m.senderId, m.date.timeIntervalSince(p.date) < groupGap, p.replyTo == m.replyTo {
                gap = 3      // measured 3 between parts of a group (text and media alike)
            } else if let p = prev, p.senderId != m.senderId || p.replyTo != m.replyTo {
                gap = 32     // a new sender, or a change of thread (measured on macOS 26)
            } else {
                gap = 12
            }
            // A reply whose root is not directly above (and that does not
            // continue the same thread) gets a preview of the root.
            if let r = m.replyTo, !threadMode, connector == nil, let p = prev, p.id != r.messageId, p.replyTo != r {
                let root = s.conversation.messages.first { $0.id == r.messageId }
                let part = root.flatMap { r.partIndex < $0.parts.count ? $0.parts[r.partIndex] : nil }
                let pv = ThreadPreview.make(root: r, part: part, count: replyCount[r.messageId] ?? 0)
                rows.append(RowSpec(key: "preview:\(m.id)", kind: .threadPreview(pv), gap: ThreadPreview.gap, height: pv.height))
                gap = ThreadPreview.replyGap
            }

            if m.retractedAt != nil {
                rows.append(RowSpec(key: "unsent:\(m.id)", kind: .unsent(outgoing: outgoing), gap: max(gap, 8), height: 16))
            } else {
                let lastOfGroup = next == nil || next!.senderId != m.senderId || next!.date.timeIntervalSince(m.date) >= groupGap
                    || next!.retractedAt != nil || next!.replyTo != m.replyTo
                for (pi, part) in m.parts.enumerated() {
                    let measured = MeasureCache.shared.size(m, pi, width: width, estimate: exact.map { !$0.contains(idx) } ?? false)
                    let (size, tl) = (measured.size, measured.text)
                    let reactions = m.reactions.filter { $0.partIndex == pi }
                    var g = pi == 0 ? gap : 3
                    // Link card then text: 3.5 pt (measured in the recording);
                    // every other pair in a group is 3 pt (macOS 26 references).
                    if g == 3, isText(part) {
                        let before: Part? = pi > 0 ? m.parts[pi - 1] : (gap == 3 ? prev?.parts.last : nil)
                        if case .link = before { g = 3.5 }
                    }
                    if pi > 0, case .text = m.parts[pi - 1], !isText(part) { g = 3 }
                    if !reactions.isEmpty { g += 10 }
                    var failed = false
                    if case .failed = m.status { failed = true }
                    let row = PartRow(ref: PartRef(messageId: m.id, partIndex: pi), part: part, outgoing: outgoing,
                                      tail: lastOfGroup && pi == m.parts.count - 1, reactions: reactions, failed: failed,
                                      size: size, text: tl, connectorRoot: pi == 0 ? connector : nil)
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
                                                                               outgoing: outgoing), gap: 0, height: 21.5))
                }
                if let r = receipts[m.id] {
                    rows.append(RowSpec(key: "receipt:\(m.id)", kind: .receipt(bold: r.0, rest: r.1), gap: 0, height: 16))
                }
            }
            prev = m
        }
        if !threadMode, span.upperBound == messages.count, s.atNewest, s.ui.typing.contains(where: { $0 != me }) {
            rows.append(RowSpec(key: "typing", kind: .typing, gap: 0, height: 35))
        }
        for i in rows.indices { rows[i].width = width }
        return rows
    }

    /// The message id of a row key ("kind:messageID[:part]"), without allocating.
    static func owner(_ key: String) -> Substring? {
        guard let a = key.firstIndex(of: ":") else { return nil }
        let rest = key[key.index(after: a)...]
        return rest.firstIndex(of: ":").map { rest[..<$0] } ?? rest
    }

    /// Whether a row key belongs to a message (keys are "kind:messageID[:part]").
    static func key(_ key: String, belongsTo id: ID) -> Bool {
        let parts = key.split(separator: ":", maxSplits: 2)
        return parts.count >= 2 && parts[1] == id
    }

    private static func isText(_ p: Part?) -> Bool { if case .text = p { return true } else { return false } }

    /// "Read <time>" under my latest read message; "Delivered" under my
    /// latest delivered message when it is newer.
    static func receiptTargets(_ messages: [Message], me: ID) -> [ID: (String, String)] {
        var lastRead: (Int, Message, String)?
        var lastDelivered: (Int, Message)?
        for (i, m) in messages.enumerated() where m.senderId == me && m.retractedAt == nil {
            switch m.status {
            case let .read(at): lastRead = (i, m, at)
            case .delivered: lastDelivered = (i, m)
            default: break
            }
        }
        var out: [ID: (String, String)] = [:]
        if let r = lastRead { out[r.1.id] = (Strings.read, "\u{00A0}" + Format.time(Instant.parse(r.2))) }
        if let d = lastDelivered, d.0 > (lastRead?.0 ?? -1) { out[d.1.id] = (Strings.delivered, "") }
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
    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }
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
    static func day(_ d: Date, now: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return Strings.today }
        if days == 1 { return Strings.yesterday }
        if days < 7 { return weekday.string(from: d) }
        return days < 300 ? monthDay.string(from: d) : monthDayYear.string(from: d)
    }
    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
    static func duration(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

/// cmux: `bundle: .module` (the catalog is the package's, not the app's).
enum Strings {
    static var today: String { String(localized: "separator.today", defaultValue: "Today", bundle: .module) }
    static var yesterday: String { String(localized: "separator.yesterday", defaultValue: "Yesterday", bundle: .module) }
    static var read: String { String(localized: "receipt.read", defaultValue: "Read", bundle: .module) }
    static var delivered: String { String(localized: "receipt.delivered", defaultValue: "Delivered", bundle: .module) }
    static var edited: String { String(localized: "label.edited", defaultValue: "Edited", bundle: .module) }
    static var notDelivered: String { String(localized: "label.notDelivered", defaultValue: "Not Delivered", bundle: .module) }
    static var unsentMine: String { String(localized: "row.unsent.mine", defaultValue: "You unsent a message", bundle: .module) }
    static var unsentTheirs: String { String(localized: "row.unsent.theirs", defaultValue: "A message was unsent", bundle: .module) }
    static func replies(_ n: Int) -> String {
        String(format: String(localized: "label.replies", defaultValue: "%lld Replies", bundle: .module), n)
    }
    static var location: String { String(localized: "preview.location", defaultValue: "Location", bundle: .module) }
    static func fileKind(_ a: Attachment) -> String {
        switch (a.fileName as NSString).pathExtension.lowercased() {
        case "pdf": return String(localized: "file.kind.pdf", defaultValue: "PDF Document", bundle: .module)
        case "zip": return String(localized: "file.kind.zip", defaultValue: "ZIP Archive", bundle: .module)
        case "m4a", "mp3", "wav", "aac": return String(localized: "file.kind.audio", defaultValue: "Audio Recording", bundle: .module)
        default: return String(localized: "file.kind.document", defaultValue: "Document", bundle: .module)
        }
    }
    // cmux: not "iMessage" (Apple's service name).
    static var placeholder: String { String(localized: "compose.placeholder", defaultValue: "Message", bundle: .module) }
    static var replyPlaceholder: String { String(localized: "compose.placeholder.reply", defaultValue: "Reply", bundle: .module) }
    static var menuReply: String { String(localized: "menu.reply", defaultValue: "Reply", bundle: .module) }
    static var menuCopy: String { String(localized: "menu.copy", defaultValue: "Copy", bundle: .module) }
    static var menuEdit: String { String(localized: "menu.edit", defaultValue: "Edit", bundle: .module) }
    static var menuUndoSend: String { String(localized: "menu.undoSend", defaultValue: "Undo Send", bundle: .module) }
    static var menuTapback: String { String(localized: "menu.tapback", defaultValue: "Tapback", bundle: .module) }
    static func tapbackName(_ t: String) -> String {
        switch t {
        case "love": return String(localized: "tapback.love", defaultValue: "Love", bundle: .module)
        case "like": return String(localized: "tapback.like", defaultValue: "Like", bundle: .module)
        case "dislike": return String(localized: "tapback.dislike", defaultValue: "Dislike", bundle: .module)
        case "laugh": return String(localized: "tapback.laugh", defaultValue: "Laugh", bundle: .module)
        case "emphasize": return String(localized: "tapback.emphasize", defaultValue: "Emphasize", bundle: .module)
        default: return String(localized: "tapback.question", defaultValue: "Question", bundle: .module)
        }
    }
    static var laughGlyph: String { String(localized: "tapback.laugh.glyph", defaultValue: "HA\nHA", bundle: .module) }
}

extension CGSize: @retroactive Hashable {
    public func hash(into h: inout Hasher) { h.combine(width); h.combine(height) }
}
