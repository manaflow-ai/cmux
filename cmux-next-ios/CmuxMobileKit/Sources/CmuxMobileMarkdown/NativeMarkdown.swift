#if os(iOS)
import CmuxMobileDesign
import UIKit

/// Text styles for views drawn without SwiftUI, at one Dynamic Type size.
/// Built off the main thread with the rest of a layout.
public struct NativeTextStyles: @unchecked Sendable {
    public let category: UIContentSizeCategory
    public let traits: UITraitCollection

    public init(category: UIContentSizeCategory) {
        self.category = category
        traits = UITraitCollection(preferredContentSizeCategory: category)
    }

    public func font(_ style: UIFont.TextStyle) -> UIFont {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
    }

    public func font(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: font(style).pointSize, weight: weight)
    }

    public func italic(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    public func mono(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// A `@ScaledMetric` value: `value` at the default size, scaled like `style`.
    public func scaled(_ value: CGFloat, relativeTo style: UIFont.TextStyle) -> CGFloat {
        UIFontMetrics(forTextStyle: style).scaledValue(for: value, compatibleWith: traits)
    }

    public var isAccessibilitySize: Bool { category.isAccessibilityCategory }
}

/// Rounds up to the display's pixel grid (3x), as SwiftUI sizes text; whole points add up in a stack.
@inline(__always) func pixelCeil(_ value: CGFloat) -> CGFloat { (value * 3).rounded(.up) / 3 }

/// Height of attributed text laid out at `width` (UILabel, any number of lines).
public func nativeTextSize(_ text: NSAttributedString, width: CGFloat, maxLines: Int = 0) -> CGSize {
    guard text.length > 0, width > 0 else { return .zero }
    if maxLines > 0 {
        // A line-capped label: measure with TextKit's line limit.
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = .byTruncatingTail
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let rect = manager.usedRect(for: container)
        let leading = (text.attributes(at: text.length - 1, effectiveRange: nil)[.font] as? UIFont)?.leading ?? 0
        return CGSize(width: min(ceil(rect.width) + 1, width), height: pixelCeil(rect.height - max(0, leading)))
    }
    let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    // SwiftUI's Text (and the web view) leave no leading under the last line: n lines are
    // lineHeight + (n - 1) x (lineHeight + leading). Lines with a fixed height have none to drop.
    // UILabel draws no leading under the last line (a fixed line height gets it added too).
    var height = rect.height
    if let font = text.attributes(at: text.length - 1, effectiveRange: nil)[.font] as? UIFont {
        height -= max(0, font.leading)
    }
    // One point of width to spare: a label sized to the exact measure can still truncate
    // its last glyph (a symbol attachment's rounding), never wider than offered.
    return CGSize(width: min(ceil(rect.width) + 1, width), height: pixelCeil(height))
}

/// Markdown laid out for UIKit: the Feed web renderer's look (markdown.css)
/// as attributed text, code cards and tables, measured at one width. Pure
/// value work, so a list lays out its rows off the main thread and a row
/// that scrolls in only places views (verify/feed-perf-20261022.md).
/// Bodies with math need the web renderer (`needsWeb`).
public struct NativeMarkdownLayout: @unchecked Sendable {
    public struct CodeBlock {
        public var frame: CGRect
        public var header: NSAttributedString
        public var headerFrame: CGRect
        public var body: NSAttributedString
        /// The code's own frame inside its horizontal scroll area (content may be wider than the card).
        public var bodyFrame: CGRect
        public var scrollFrame: CGRect
    }

    public struct TableBlock {
        public var frame: CGRect
        /// Every cell's text and frame, in the table's own coordinates.
        public var cells: [(text: NSAttributedString, frame: CGRect)]
        /// Hairline rules under each row.
        public var rules: [CGRect]
        public var contentSize: CGSize
    }

    public enum Block {
        case text(NSAttributedString, CGRect)
        case code(CodeBlock)
        case table(TableBlock)
        case quote(text: NSAttributedString, textFrame: CGRect, bar: CGRect)
        case rule(CGRect)
    }

    public var blocks: [Block]
    public var height: CGFloat
    /// The body has math: only the web renderer draws it as the Mac does.
    public var needsWeb: Bool

    public static func make(markdown: String, width: CGFloat, styles: NativeTextStyles) -> NativeMarkdownLayout {
        let document = MarkdownDocument(parsing: markdown)
        if document.needsWebRenderer { return NativeMarkdownLayout(blocks: [], height: 0, needsWeb: true) }
        var builder = Builder(width: width, styles: styles)
        for block in document.blocks { builder.add(block.kind) }
        return builder.finish()
    }

    // MARK: Building

    /// markdown.css margins: (top, bottom) per block; adjacent margins collapse.
    enum Margin {
        static func of(_ kind: MarkdownBlock.Kind) -> (top: CGFloat, bottom: CGFloat) {
            switch kind {
            case .heading(let level, _): level == 1 ? (18, 8) : level == 2 ? (16, 8) : (14, 6)
            case .rule: (14, 14)
            case .math: (4, 12)
            default: (0, 12)
            }
        }
    }

    struct Builder {
        let width: CGFloat
        let styles: NativeTextStyles
        var blocks: [Block] = []
        var y: CGFloat = 0
        var pendingBottom: CGFloat?
        /// Text blocks waiting to be merged into one label: paragraphs, headings, lists.
        var run = NSMutableAttributedString()
        var runTop: CGFloat = 0

        init(width: CGFloat, styles: NativeTextStyles) {
            self.width = width
            self.styles = styles
        }

        var body: UIFont { styles.font(.body) }
        var lineHeight: CGFloat { (body.pointSize * 1.6).rounded() }
        /// CSS puts half a line's extra height above its glyphs; TextKit puts all of a fixed line's
        /// extra (less the leading it adds under the line) above them. A block moved by this
        /// lands where the web renderer drew it (measured on the iOS 26.5 simulator).
        func halfLeading(_ font: UIFont, _ lineHeight: CGFloat) -> CGFloat { -((lineHeight - font.lineHeight) / 2 - max(0, font.leading)) }

        /// Space before a block with `top` margin after the previous block's bottom margin.
        mutating func gap(_ top: CGFloat) -> CGFloat {
            defer { pendingBottom = nil }
            guard let bottom = pendingBottom else { return 0 }
            return max(bottom, top)
        }

        mutating func add(_ kind: MarkdownBlock.Kind) {
            let margin = Margin.of(kind)
            switch kind {
            case .paragraph(let text):
                appendText(inline(text.replacingOccurrences(of: "\n", with: " "), font: body, lineHeight: lineHeight), margin: margin)
            case .heading(let level, let text):
                let font: UIFont = level == 1 ? styles.font(.title3, weight: .bold) : level == 2 ? styles.font(.headline)
                    : styles.font(.subheadline, weight: .bold)
                appendText(inline(text, font: font, lineHeight: (font.pointSize * 1.6).rounded()), margin: margin)
            case .list(let list):
                appendText(listText(list), margin: margin)
            case .quote(let text):
                flushRun()
                let top = y + gap(margin.top)
                let color = UIColor.secondaryLabel
                let attributed = inline(text.replacingOccurrences(of: "\n", with: " "), font: body, lineHeight: lineHeight, color: color)
                let size = nativeTextSize(attributed, width: width - 15)
                blocks.append(.quote(text: attributed, textFrame: CGRect(x: 15, y: top + halfLeading(body, lineHeight), width: width - 15, height: size.height),
                                     bar: CGRect(x: 0, y: top, width: 3, height: size.height)))
                y = top + size.height
                pendingBottom = margin.bottom
            case .rule:
                flushRun()
                let top = y + gap(margin.top)
                blocks.append(.rule(CGRect(x: 0, y: top, width: width, height: 0.5)))
                y = top + 0.5
                pendingBottom = margin.bottom
            case .code(let language, let code, _):
                flushRun()
                let top = y + gap(margin.top)
                let block = codeBlock(language: language, code: code, top: top)
                blocks.append(.code(block))
                y = block.frame.maxY
                pendingBottom = margin.bottom
            case .table(let table):
                flushRun()
                let top = y + gap(margin.top)
                let block = tableBlock(table, top: top)
                blocks.append(.table(block))
                y = block.frame.maxY
                pendingBottom = margin.bottom
            case .math:
                break
            }
        }

        /// Adds text to the current label run, its paragraph spacing standing in for the margins.
        mutating func appendText(_ text: NSAttributedString, margin: (top: CGFloat, bottom: CGFloat)) {
            if run.length == 0 {
                runTop = y + gap(margin.top)
            } else {
                // The gap between this block and the previous one: the previous paragraph's spacing.
                let space = max(pendingBottom ?? 0, margin.top)
                pendingBottom = nil
                setLastParagraphSpacing(space)
                // The separator keeps the previous line's font and paragraph (a bare newline lays out a default line).
                let last = run.attributes(at: run.length - 1, effectiveRange: nil)
                run.append(NSAttributedString(string: "\n", attributes: [.font: last[.font] ?? body,
                                                                         .paragraphStyle: last[.paragraphStyle] ?? NSParagraphStyle.default]))
            }
            run.append(text)
            pendingBottom = margin.bottom
        }

        mutating func setLastParagraphSpacing(_ space: CGFloat) {
            let full = run.string as NSString
            let start = full.paragraphRange(for: NSRange(location: max(0, run.length - 1), length: 0))
            // TextKit adds the font's leading after a paragraph's last line too.
            let leading = (run.attributes(at: max(0, run.length - 1), effectiveRange: nil)[.font] as? UIFont)?.leading ?? 0
            run.enumerateAttribute(.paragraphStyle, in: start) { value, range, _ in
                let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.paragraphSpacing = max(0, space - max(0, leading))
                run.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }

        mutating func flushRun() {
            guard run.length > 0 else { return }
            let text = NSAttributedString(attributedString: run)
            let size = nativeTextSize(text, width: width)
            blocks.append(.text(text, CGRect(x: 0, y: runTop + halfLeading(body, lineHeight), width: width, height: size.height)))
            y = runTop + size.height
            run = NSMutableAttributedString()
        }

        mutating func finish() -> NativeMarkdownLayout {
            flushRun()
            return NativeMarkdownLayout(blocks: blocks, height: ceil(y), needsWeb: false)
        }

        // MARK: Inline text

        /// A paragraph whose lines are `lineHeight` apart (TextKit adds the font's leading to a fixed
        /// line height, so the fixed height leaves it out).
        func paragraphStyle(lineHeight: CGFloat, font: UIFont? = nil) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            let fixed = lineHeight - max(0, (font ?? body).leading)
            style.minimumLineHeight = fixed
            style.maximumLineHeight = fixed
            style.lineBreakMode = .byWordWrapping
            // Greedy line breaks, as the web renderer's CSS (no orphan avoidance).
            style.lineBreakStrategy = []
            return style
        }

        /// Inline markdown (bold, italic, code, links, strikethrough) in markdown.css's look.
        func inline(_ source: String, font: UIFont, lineHeight: CGFloat, color: UIColor = .label,
                    paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
            NativeMarkdownLayout.inlineText(source, font: font, color: color, styles: styles,
                                        paragraph: paragraph ?? paragraphStyle(lineHeight: lineHeight, font: font), lineHeight: lineHeight)
        }

        func listText(_ list: MarkdownList) -> NSAttributedString {
            let output = NSMutableAttributedString()
            for (index, item) in list.items.enumerated() {
                let indent = 22 + CGFloat(item.depth) * 22
                let style = paragraphStyle(lineHeight: lineHeight)
                style.headIndent = indent
                style.firstLineHeadIndent = indent - 22
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                style.paragraphSpacing = index < list.items.count - 1 ? max(0, 4 - max(0, body.leading)) : 0
                let marker = item.ordinal.map { "\($0)." } ?? "•"
                let check = item.checked.map { $0 ? "☑︎ " : "☐ " } ?? ""
                output.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: body, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style,

                ]))
                output.append(inline(check + item.text, font: body, lineHeight: lineHeight, paragraph: style))
                if index < list.items.count - 1 { output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])) }
            }
            return output
        }

        // MARK: Code

        func codeBlock(language: String?, code: String, top: CGFloat) -> CodeBlock {
            let lang = (language ?? "").split(separator: " ").first.map { String($0).lowercased() } ?? ""
            let names = ["swift": "Swift", "py": "Python", "python": "Python", "ts": "TypeScript", "js": "JavaScript", "rs": "Rust",
                         "rust": "Rust", "sh": "Bash", "bash": "Bash", "diff": "Diff", "json": "JSON"]
            let label = names[lang] ?? (lang.isEmpty ? "Code" : lang.prefix(1).uppercased() + lang.dropFirst())
            let headerFont = styles.font(.footnote, weight: .medium)
            let header = NSAttributedString(string: label, attributes: [.font: headerFont, .foregroundColor: UIColor.secondaryLabel])
            let headerHeight = ceil(headerFont.lineHeight)
            // `pre` keeps the body's line box (1.6 x the body size), wider than the code's own 19 px.
            let pitch = lineHeight
            let body = NativeMarkdownLayout.codeText(code, language: lang, font: styles.mono(size: 13), lineHeight: pitch)
            let lines = max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)
            let natural = nativeTextSize(body, width: .greatestFiniteMagnitude)
            let bodyHeight = CGFloat(lines) * pitch
            let headerFrame = CGRect(x: 14, y: 10, width: width - 28, height: headerHeight)
            let scrollTop = headerFrame.maxY + 2
            let scroll = CGRect(x: 0, y: scrollTop, width: width, height: 4 + bodyHeight + 14)
            let codeFont = styles.mono(size: 13)
            let bodyFrame = CGRect(x: 14, y: 4 + halfLeading(codeFont, pitch), width: max(natural.width, 1), height: bodyHeight)
            return CodeBlock(frame: CGRect(x: 0, y: top, width: width, height: scroll.maxY), header: header, headerFrame: headerFrame,
                             body: body, bodyFrame: bodyFrame, scrollFrame: scroll)
        }

        // MARK: Tables

        func tableBlock(_ table: MarkdownTable, top: CGFloat) -> TableBlock {
            let font = styles.font(.subheadline)
            let bold = styles.font(.subheadline, weight: .semibold)
            let lh = (font.pointSize * 1.6).rounded()
            let columns = table.columnCount
            let rows = [table.header] + table.rows
            var texts: [[NSAttributedString]] = []
            var widths = Array(repeating: CGFloat(64), count: columns)
            for (r, row) in rows.enumerated() {
                var line: [NSAttributedString] = []
                for c in 0..<columns {
                    let source = c < row.count ? row[c] : ""
                    let style = paragraphStyle(lineHeight: lh, font: r == 0 ? bold : font)
                    switch c < table.alignments.count ? table.alignments[c] : .leading {
                    case .leading: style.alignment = .left
                    case .center: style.alignment = .center
                    case .trailing: style.alignment = .right
                    }
                    let text = inline(source, font: r == 0 ? bold : font, lineHeight: lh, paragraph: style)
                    widths[c] = max(widths[c], nativeTextSize(text, width: .greatestFiniteMagnitude).width)
                    line.append(text)
                }
                texts.append(line)
            }
            var cells: [(NSAttributedString, CGRect)] = []
            var rules: [CGRect] = []
            var y: CGFloat = 0
            let total = widths.reduce(0) { $0 + $1 + 12 }
            for (r, line) in texts.enumerated() {
                var x: CGFloat = 0
                for (c, text) in line.enumerated() {
                    cells.append((text, CGRect(x: x, y: y + 8 + halfLeading(r == 0 ? bold : font, lh), width: widths[c], height: lh)))
                    x += widths[c] + 12
                }
                y += 8 + lh + 8
                rules.append(CGRect(x: 0, y: y - 0.5, width: total, height: 0.5))
            }
            return TableBlock(frame: CGRect(x: 0, y: top, width: width, height: y), cells: cells, rules: rules,
                              contentSize: CGSize(width: total, height: y))
        }
    }
}

/// Inline markdown to UIKit attributes (markdown.css: strong 600, code mono
/// .88em on fill-selected, links underlined in the label color).
extension NativeMarkdownLayout {
    /// The URL under a run of native markdown (not `.link`: UILabel would recolor it blue).
    public static let linkKey = NSAttributedString.Key("cmuxMobile.link")

    /// `codeBackground`: markdown.css's fill behind code spans (web bodies); SwiftUI's Text draws none.
    public static func inlineText(_ source: String, font: UIFont, color: UIColor, styles: NativeTextStyles,
                                  paragraph: NSParagraphStyle, lineHeight: CGFloat? = nil, codeBackground: Bool = true) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let output = NSMutableAttributedString()
        // No baseline offset: a fixed-height line keeps its glyphs at the top and its extra space
        // under them (an offset would grow the line); the block is moved down by `halfLeading` instead.
        let offset: CGFloat = 0
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: paragraph]
            if offset != 0 { attributes[.baselineOffset] = offset }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { runFont = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold) }
                if intent.contains(.emphasized) { runFont = styles.italic(runFont) }
                if intent.contains(.code) {
                    runFont = codeBackground ? styles.mono(size: (font.pointSize * 0.88).rounded()) : styles.mono(size: font.pointSize)
                    if codeBackground { attributes[.backgroundColor] = UIColor.cmuxMobileFillSelected }
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            // Links, as the web renderer drew them (it did not link file paths in code spans).
            if let link = run.link {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[NativeMarkdownLayout.linkKey] = link
            }
            attributes[.font] = runFont
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            if isCode, codeBackground, output.length > 0 {
                // markdown.css: `code { padding: 1px 3px }`, 3 pt of room on each side of the span.
                let before = NSRange(location: output.length - 1, length: 1)
                let kern = (output.attribute(.kern, at: before.location, effectiveRange: nil) as? CGFloat) ?? 0
                output.addAttribute(.kern, value: kern + 3, range: before)
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
            if isCode, codeBackground, output.length > 0 {
                output.addAttribute(.kern, value: 3, range: NSRange(location: output.length - 1, length: 1))
            }
        }
        return output
    }
}

/// Code as UIKit attributed text: the web renderer's diff colors, or the
/// syntax palette for a known language.
extension NativeMarkdownLayout {
    public static func codeText(_ code: String, language: String?, font: UIFont, lineHeight: CGFloat,
                                   lineSpacing: CGFloat? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        if let lineSpacing {
            paragraph.lineSpacing = lineSpacing
        } else {
            // TextKit adds the font's leading to a fixed line height: leave it out.
            paragraph.minimumLineHeight = lineHeight - max(0, font.leading)
            paragraph.maximumLineHeight = lineHeight - max(0, font.leading)
        }
        paragraph.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
                                                   .baselineOffset: 0]
        let output = NSMutableAttributedString()
        let lang = language?.lowercased() ?? ""
        if lang == "diff" {
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                var attributes = base
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                    attributes[.foregroundColor] = UIColor.tertiaryLabel
                } else if line.hasPrefix("@@") {
                    attributes[.foregroundColor] = UIColor.cmuxMobileSyntaxFunction
                } else if line.hasPrefix("+") {
                    attributes[.foregroundColor] = UIColor.cmuxMobileDiffAddText
                } else if line.hasPrefix("-") {
                    attributes[.foregroundColor] = UIColor.cmuxMobileDiffDelText
                }
                output.append(NSAttributedString(string: String(line) + (index < lines.count - 1 ? "\n" : ""), attributes: attributes))
            }
            return output
        }
        let known = ["swift", "py", "python", "rs", "rust", "sh", "bash", "shell", "zsh", "console", "js", "javascript", "ts",
                     "typescript", "tsx", "json", "go", "yaml", "yml", "toml"]
        guard known.contains(lang) else { return NSAttributedString(string: code, attributes: base) }
        for piece in SyntaxHighlighter(language: lang).pieces(code) {
            var attributes = base
            if let token = piece.token { attributes[.foregroundColor] = SyntaxHighlighter.uiColor(token) }
            output.append(NSAttributedString(string: piece.text, attributes: attributes))
        }
        return output
    }
}

/// Draws a `NativeMarkdownLayout`, reusing its labels, code cards and tables
/// from one layout to the next (a recycled Feed cell keeps its views).
public final class NativeMarkdownView: UIView {
    private var labels: [UILabel] = []
    private var codes: [NativeCodeCardView] = []
    private var tables: [NativeTableView] = []
    private var bars: [UIView] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The link at `point` (in this view), if a label's text has one there.
    public func link(at point: CGPoint) -> URL? {
        for label in labels where !label.isHidden && label.frame.contains(point) {
            if let url = Self.link(in: label, at: CGPoint(x: point.x - label.frame.minX, y: point.y - label.frame.minY)) { return url }
        }
        return nil
    }

    /// The link under `point` (in `label`'s coordinates): only on the glyph itself, not the blank
    /// space after a line or between paragraphs.
    public static func link(in label: UILabel, at point: CGPoint) -> URL? {
        guard let text = label.attributedText, text.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        // Unbounded height: the label's height leaves out the last line's leading TextKit adds.
        let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var fraction: CGFloat = 0
        let glyph = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -4, dy: -4)
        guard rect.contains(point) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < text.length else { return nil }
        return text.attribute(NativeMarkdownLayout.linkKey, at: index, effectiveRange: nil) as? URL
    }

    public func apply(_ layout: NativeMarkdownLayout) {
        var label = 0, code = 0, table = 0, bar = 0
        func nextLabel() -> UILabel {
            if label == labels.count {
                let view = UILabel()
                view.numberOfLines = 0
                // Text draws off the main thread at commit (a row's first draw stays out of the frame).
                view.layer.drawsAsynchronously = true
                labels.append(view)
                addSubview(view)
            }
            defer { label += 1 }
            return labels[label]
        }
        func nextBar() -> UIView {
            if bar == bars.count {
                let view = UIView()
                bars.append(view)
                addSubview(view)
            }
            defer { bar += 1 }
            return bars[bar]
        }
        for block in layout.blocks {
            switch block {
            case .text(let text, let frame):
                let view = nextLabel()
                view.attributedText = text
                view.frame = frame
                view.isHidden = false
            case .quote(let text, let textFrame, let barFrame):
                let view = nextLabel()
                view.attributedText = text
                view.frame = textFrame
                view.isHidden = false
                let line = nextBar()
                line.backgroundColor = .separator
                line.frame = barFrame
                line.isHidden = false
            case .rule(let frame):
                let line = nextBar()
                line.backgroundColor = .separator
                line.frame = frame
                line.isHidden = false
            case .code(let block):
                if code == codes.count {
                    let view = NativeCodeCardView()
                    codes.append(view)
                    addSubview(view)
                }
                codes[code].apply(block)
                codes[code].isHidden = false
                code += 1
            case .table(let block):
                if table == tables.count {
                    let view = NativeTableView()
                    tables.append(view)
                    addSubview(view)
                }
                tables[table].apply(block)
                tables[table].isHidden = false
                table += 1
            }
        }
        for view in labels[label...] { view.isHidden = true; view.attributedText = nil }
        for view in codes[code...] { view.isHidden = true }
        for view in tables[table...] { view.isHidden = true }
        for view in bars[bar...] { view.isHidden = true }
    }
}

/// A markdown code card (markdown.css `.code`): header, then the code in a
/// horizontal scroll area with a trailing fade while more is off screen.
final class NativeCodeCardView: UIView, UIScrollViewDelegate {
    private let header = UILabel()
    private let scroll = UIScrollView()
    private let code = UILabel()
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .cmuxMobileCodeBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
        addSubview(header)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.delegate = self
        scroll.addSubview(code)
        code.numberOfLines = 0
        addSubview(scroll)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ block: NativeMarkdownLayout.CodeBlock) {
        frame = block.frame
        header.attributedText = block.header
        header.frame = block.headerFrame
        scroll.frame = block.scrollFrame
        code.attributedText = block.body
        code.frame = block.bodyFrame
        scroll.contentSize = CGSize(width: block.bodyFrame.maxX + 14, height: block.scrollFrame.height)
        scroll.contentOffset = .zero
        updateFade()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFade() }

    private func updateFade() {
        let more = scroll.contentOffset.x + scroll.bounds.width < scroll.contentSize.width - 1
        if more {
            fade.frame = scroll.bounds
            let width = max(scroll.bounds.width, 1)
            fade.locations = [0, NSNumber(value: Double((width - 16) / width)), 1]
            scroll.layer.mask = fade
        } else {
            scroll.layer.mask = nil
        }
    }
}

/// A markdown table (markdown.css `table`) in a horizontal scroll area.
final class NativeTableView: UIScrollView {
    private var labels: [UILabel] = []
    private var rules: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ block: NativeMarkdownLayout.TableBlock) {
        frame = block.frame
        contentSize = block.contentSize
        contentOffset = .zero
        while labels.count < block.cells.count {
            let label = UILabel()
            label.numberOfLines = 1
            labels.append(label)
            addSubview(label)
        }
        while rules.count < block.rules.count {
            let rule = UIView()
            rule.backgroundColor = .separator
            rules.append(rule)
            addSubview(rule)
        }
        for (index, label) in labels.enumerated() {
            label.isHidden = index >= block.cells.count
            guard index < block.cells.count else { continue }
            label.attributedText = block.cells[index].text
            label.frame = block.cells[index].frame
        }
        for (index, rule) in rules.enumerated() {
            rule.isHidden = index >= block.rules.count
            if index < block.rules.count { rule.frame = block.rules[index] }
        }
    }
}

/// The web renderer as a plain UIKit view, for bodies only it can draw
/// (math): a pooled web view, its content height reported as it measures.
public final class WebMarkdownUIView: UIView {
    private var web: PooledWebView?
    private var shown: String?
    public var onHeight: ((CGFloat) -> Void)?
    public var onTap: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `markdown` (a JavaScript render into a pooled view; nothing when it already shows it).
    public func show(_ markdown: String, contentHeight: CGFloat) {
        let view: PooledWebView
        if let web {
            view = web
        } else {
            view = WebMarkdownRenderer.shared.dequeue()
            addSubview(view)
            web = view
        }
        view.onHeight = { [weak self] height in
            guard let self, let shown = self.shown else { return }
            WebMarkdownRenderer.shared.store(height: height, markdown: shown, style: .body, width: self.bounds.width)
            self.onHeight?(height)
        }
        view.onTap = { [weak self] in self?.onTap?() }
        view.contentHeight = contentHeight
        view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(contentHeight, bounds.height))
        if shown != markdown {
            shown = markdown
            view.render(markdown: markdown, style: .body)
        }
    }

    /// Gives the web view back to the pool (a placeholder shows instead).
    public func release() {
        guard let web else { return }
        web.onHeight = nil
        WebMarkdownRenderer.shared.enqueue(web)
        self.web = nil
        shown = nil
    }

    public var isShowing: Bool { web != nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if let web { web.frame.size.width = bounds.width }
    }
}
#endif
