import AppKit
import os

/// cmux: what a link chip in Home points at (plans/cmux-next/home-link-chips-DESIGN.md). Each
/// kind has its icon (an SF Symbol name). A link with no kind stays plain link text.
public enum HomeLinkChipKind: String, CaseIterable, Sendable {
    /// `cmux://workspace/ws_…`.
    case workspace
    /// `cmux://pane/pane_…`.
    case pane
    /// `cmux://tab/tab_…` whose content kind is not known.
    case tab
    /// A tab the host knows is a terminal.
    case terminal
    /// A tab the host knows is a browser page.
    case browser
    /// An agent chat (`cmux://session/<id>`, an ACP session).
    case session
    /// A Chief subagent's chat (`cmux://chief/<home>/session/<id>`).
    case subagent
    /// A local folder (`file://…/`, or a path with no extension).
    case folder
    /// A Markdown document.
    case markdown
    /// A local image.
    case image
    /// A source file.
    case code
    /// Any other local file.
    case file
    /// A GitHub pull request.
    case pullRequest
    /// A GitHub issue.
    case issue
    /// A GitHub commit.
    case commit
    /// A GitHub Actions run.
    case run

    /// The SF Symbol the chip draws before its label.
    public var symbolName: String {
        switch self {
        case .workspace: "macwindow"
        case .pane: "rectangle.split.2x1"
        case .tab: "square.on.square"
        case .terminal: "terminal"
        case .browser: "globe"
        case .session: "bubble.left.and.bubble.right"
        case .subagent: "person.2"
        case .folder: "folder"
        case .markdown: "doc.richtext"
        case .image: "photo"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .file: "doc"
        case .pullRequest: "arrow.triangle.pull"
        case .issue: "exclamationmark.circle"
        case .commit: "smallcircle.filled.circle"
        case .run: "play.circle"
        }
    }
}

/// cmux: the chip a link shows as, and the chip's geometry. Pure functions of the link text;
/// the host's live facts (title, closed state) belong to the hover card.
enum HomeLinkChip {
    /// Whether an agent's reply in the transcript draws its links as chips. Off: Lawrence
    /// 2026-10-20 called the pills ugly (icon over the text, other size) and asked to revert
    /// to plain links until he picks a design from plans/cmux-next/home-agent-refs/gallery.html.
    static let showsInTranscript = false
    /// The style a chip's runs carry (`chip:<kind>`); TextLayout and RowDraw read it.
    static let stylePrefix = "chip:"
    /// The one character before a chip's label that holds its icon.
    static let pad: Character = "\u{00A0}"
    /// The width the pad takes: left inset, icon, gap.
    static let iconSlot: CGFloat = 17
    /// The space after the label, inside the pill.
    static let trailingPad: CGFloat = 5
    /// The icon's point size.
    static let iconSize: CGFloat = 11
    /// A label this short (UTF-16 units) never wraps inside its chip.
    static let unbrokenLabel = 40

    /// The chip `link` (a sanitized link destination) shows as, or nil for plain link text.
    static func kind(for link: String) -> HomeLinkChipKind? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return nil }
        if url.isChiefSubagentLink { return .subagent }
        if url.isCmuxAppLink {
            switch url.host?.lowercased() {
            case "workspace": return .workspace
            case "pane": return .pane
            case "tab": return .tab
            case "session": return .session
            default: return nil
            }
        }
        if url.isHomePathLink { return fileKind(url) }
        guard scheme == "https", url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        switch parts[2] {
        case "pull": return Int(parts[3], radix: 10) != nil ? .pullRequest : nil
        case "issues": return Int(parts[3], radix: 10) != nil ? .issue : nil
        case "commit": return parts[3].count >= 7 && parts[3].allSatisfy(\.isHexDigit) ? .commit : nil
        case "actions": return parts.count >= 5 && parts[3] == "runs" && Int(parts[4], radix: 10) != nil ? .run : nil
        default: return nil
        }
    }

    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp"]
    private static let sources: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "rs", "py", "go", "json", "c", "h", "m", "mm",
                                               "cpp", "zig", "sh", "rb", "java", "kt", "css", "html", "yml", "yaml", "toml"]

    private static func fileKind(_ url: URL) -> HomeLinkChipKind {
        if url.absoluteString.hasSuffix("/") { return .folder }
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return .folder }
        if ext == "md" || ext == "markdown" { return .markdown }
        if images.contains(ext) { return .image }
        if sources.contains(ext) { return .code }
        return .file
    }

    /// The label a chip shows: a short one with no-break spaces, so it wraps as one unit.
    static func label(_ s: String) -> String {
        (s as NSString).length <= unbrokenLabel ? s.replacingOccurrences(of: " ", with: "\u{00A0}") : s
    }
}

extension TextRun {
    /// The chip this run is part of, nil for any other run.
    var chipKind: HomeLinkChipKind? {
        guard let s = style?.first(where: { $0.hasPrefix(HomeLinkChip.stylePrefix) }) else { return nil }
        return HomeLinkChipKind(rawValue: String(s.dropFirst(HomeLinkChip.stylePrefix.count)))
    }
}

/// cmux: one chip's part of one line: from `x0` to `x1` (line-local, the pad included), and
/// whether the icon is on this line (the chip's first part).
struct HomeLinkChipSpan: Equatable {
    var kind: HomeLinkChipKind
    var link: String
    var x0: CGFloat
    var x1: CGFloat
    var hasIcon: Bool
}

extension TextLayout {
    /// The chips of line `i`, left to right (one entry per chip part on the line).
    /// `attr`: this layout's drawn text when the caller has it (one build per bubble, not per line).
    func chipSpans(line i: Int, attr given: NSAttributedString? = nil) -> [HomeLinkChipSpan] {
        guard runs.contains(where: { $0.chipKind != nil }), let range = lines[checked: i]?.range, range.length > 0 else { return [] }
        let attr = given ?? attributed(color: .white, linkColor: .white)
        guard let lineText = attr.checkedAttributedSubstring(range) else { return [] }
        let line = CTLineCreateWithAttributedString(lineText)
        let ns = text as NSString
        var out: [HomeLinkChipSpan] = []
        for (n, r) in runs.enumerated() {
            guard let kind = r.chipKind, let link = r.link else { continue }
            let lo = max(r.start, range.location), hi = min(r.start + r.length, range.location + range.length)
            guard hi > lo else { continue }
            let x0 = line.offset(forStringIndex: lo - range.location)
            var x1 = line.offset(forStringIndex: hi - range.location)
            // The chip's end on this line: Core Text's offset there leaves out the last
            // character's kern (the trailing pad, HomeLinkChip.reserve), the pill takes it.
            let next = runs[checked: n + 1]
            if hi == r.start + r.length, next.map({ $0.link != link || $0.start != hi }) ?? true {
                x1 += HomeLinkChip.trailingPad
            }
            let icon = lo == r.start && ns.checkedCharacter(at: r.start) == 0xA0
            // Runs of one chip (a bold word in a label) join into one part.
            if let last = out.last, last.link == link, abs(last.x1 - x0) < 0.5 {
                out.update(at: out.count - 1) { $0.x1 = x1 }
            } else {
                out.append(HomeLinkChipSpan(kind: kind, link: link, x0: x0, x1: x1, hasIcon: icon))
            }
        }
        return out
    }
}

/// cmux: the chip a pointer is on, for the host's hover card.
public struct HomeLinkChipHit: Equatable {
    /// The link the chip opens.
    public var url: URL
    /// What it points at.
    public var kind: HomeLinkChipKind
    /// The chip's part on the hovered line, in the transcript host's coordinates.
    public var rect: CGRect
}

/// cmux: chip icons, made once per symbol, colour and scale (drawing runs on RowBitmaps' threads).
enum HomeLinkChipIcons {
    // Lock carve-out: a tiny synchronous cache read from drawing threads; no async caller.
    private static let cache = OSAllocatedUnfairLock(initialState: [String: CGImage]())

    static func image(_ kind: HomeLinkChipKind, color: NSColor, scale: CGFloat) -> CGImage? {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let key = "\(kind.rawValue)|\(rgb.redComponent)|\(rgb.greenComponent)|\(rgb.blueComponent)|\(rgb.alphaComponent)|\(scale)"
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: HomeLinkChip.iconSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [rgb]))
        guard let symbol = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale))
        // SAFETY: the proposed rect is the local `rect`, lent for the call only (AppKit may write the rect it used).
        guard let cg = unsafe symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cache.withLock { if $0.count > 256 { $0.removeAll() }; $0[key] = cg }
        return cg
    }
}

extension HomeLinkChip {
    /// The pad's own width in the body font (a no-break space is as wide as a space).
    static let padWidth: CGFloat = {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{00A0}", attributes: [.font: Fixture.bodyFont]))
        return CGFloat(line.typographicWidth)
    }()

    /// Gives each chip in `a` its icon slot (kern on the pad) and its trailing pad (kern on the
    /// label's last character), and takes the underline off chips. Measure and draw both call it
    /// (TextLayout.attributed), so the wrap and the drawn text agree.
    static func reserve(in a: NSMutableAttributedString, runs: [TextRun], kern: CGFloat) {
        guard runs.contains(where: { $0.chipKind != nil }) else { return }
        let ns = a.string as NSString
        for (i, r) in runs.enumerated() where r.chipKind != nil {
            guard r.length > 0, let range = a.checkedRange(NSRange(location: r.start, length: r.length)) else { continue }
            a.removeAttribute(.underlineStyle, range: range)
            if ns.checkedCharacter(at: range.location) == 0xA0, let pad = a.checkedRange(NSRange(location: range.location, length: 1)) {
                a.addAttribute(.kern, value: kern + iconSlot - padWidth, range: pad)
            }
            let next = runs[checked: i + 1]
            let ends = next.map { $0.link != r.link || $0.start != r.start + r.length } ?? true
            if ends, let last = a.checkedRange(NSRange(location: NSMaxRange(range) - 1, length: 1)) {
                a.addAttribute(.kern, value: kern + trailingPad, range: last)
            }
        }
    }

    /// Draws the chips of one line behind its text: the pill, then the icon in the pad.
    /// `origin`: the line's left edge and baseline in `ctx` (y down).
    static func drawSpans(_ ctx: CGContext, _ spans: [HomeLinkChipSpan], origin: CGPoint, tint: NSColor, outgoing: Bool, scale: CGFloat) {
        guard !spans.isEmpty else { return }
        let fill = outgoing ? NSColor.white.withAlphaComponent(0.22) : tint.withAlphaComponent(0.14)
        for s in spans {
            let rect = pillRect(s, origin: origin)
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(CGPath.roundedRect(rect, cornerWidth: 5, cornerHeight: 5))
            ctx.fillPath()
            guard s.hasIcon, let icon = HomeLinkChipIcons.image(s.kind, color: tint, scale: scale) else { continue }
            let w = CGFloat(icon.width) / scale, h = CGFloat(icon.height) / scale
            let box = CGRect(x: rect.minX + 3.5 + max(0, (iconSize + 1 - w) / 2), y: rect.midY - h / 2, width: w, height: h)
            ctx.saveGState()
            // y-down context: flip the image locally.
            ctx.translateBy(x: box.minX, y: box.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(icon, in: CGRect(origin: .zero, size: box.size))
            ctx.restoreGState()
        }
    }

    /// A chip part's pill: around the label's glyphs, `origin` the line's left edge and baseline.
    static func pillRect(_ s: HomeLinkChipSpan, origin: CGPoint) -> CGRect {
        CGRect(x: origin.x + s.x0, y: origin.y - 12.5, width: s.x1 - s.x0, height: 17)
    }
}
