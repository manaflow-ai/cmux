#if os(iOS)
import CmuxMobileDesign
import CmuxMobileMarkdown
import UIKit

/// What a native transcript row is laid out for: its width, the text size and the
/// person's code-wrap setting. A layout is kept until one of these changes.
struct ChatNativeEnvironment: Hashable, Sendable {
    var width: CGFloat
    var category: UIContentSizeCategory
    var wrapCode: Bool
}

/// One transcript row laid out for UIKit: the look of the SwiftUI rows it replaces
/// (`MarkdownBlockView`, `CodeCard`, `MarkdownTableView`, the session line), as frames and
/// attributed text measured once at one width. Pure value work, so the transcript lays rows
/// out off the main thread and a row that scrolls in only places views.
struct ChatNativeLayout: @unchecked Sendable {
    struct Text {
        var text: NSAttributedString
        var frame: CGRect
        /// A markdown heading: VoiceOver reads it as a heading (rotor navigation).
        var isHeader = false
    }

    struct Symbol {
        var name: String
        var font: UIFont
        var color: UIColor
        var frame: CGRect
    }

    /// A filled rounded rectangle under the row's text (a bubble, a card).
    struct Box {
        var frame: CGRect
        var fill: UIColor
        var radius: CGFloat
        /// A 0.5 pt border in the separator color at half opacity.
        var bordered = false
    }

    /// Text that scrolls sideways in its own area (diff lines), with a trailing fade.
    struct Scroller {
        var frame: CGRect
        var text: Text
        var contentWidth: CGFloat
    }

    /// What a tap in a region of the row does.
    enum Hit: Sendable, Equatable {
        /// Opens or closes a disclosure (a tool row, a group, a thought, a long diff).
        case toggle(String)
        case openDiff(fileID: String?)
        /// Copies the answer; the symbol at the index turns into a checkmark for a moment.
        case copyAnswer(symbol: Int)
        case shareAnswer
        case retry
    }

    /// A tap region and how assistive technologies present it (a button with this label).
    struct HitArea {
        var frame: CGRect
        var hit: Hit
        var label: String
        /// The edited-files card's file index (its label adds "viewed" when the file is).
        var file: Int?
        /// The region is a disclosure ("collapsed" until opened).
        var isDisclosure = false
    }

    /// Text runs, SF symbols, boxes, separators and tap regions, positioned in the row.
    struct Drawn {
        var boxes: [Box] = []
        var texts: [Text] = []
        var symbols: [Symbol] = []
        var bars: [CGRect] = []
        /// A full-width hairline (a markdown rule).
        var rule: CGRect?
        /// Hairlines in the separator color (a card's dividers).
        var separators: [CGRect] = []
        var scrollers: [Scroller] = []
        var hits: [HitArea] = []
        /// A button that opens the row's "More" menu.
        var menuButton: CGRect?
        /// The whole row is one accessibility element with this label.
        var accessibilityLabel: String?
        /// File rows' symbols (by index into `symbols`) that show the viewed mark when the
        /// file at the index is viewed.
        var viewedMarks: [(symbol: Int, file: Int)] = []
    }

    struct Code {
        var code: String
        var language: String?
        var symbol: String
        var title: NSAttributedString
        var body: NSAttributedString
        /// The code's own size (wider than the card when lines do not wrap).
        var bodySize: CGSize
        var lineCount: Int
        /// The card is cut to its cap with "Show all N lines".
        var capped: Bool
        var cardHeight: CGFloat
        var showAll: NSAttributedString
    }

    struct Table {
        var cells: [Text]
        var rules: [CGRect]
        var contentSize: CGSize
        var plainText: String
    }

    enum Content {
        case drawn(Drawn)
        case code(Code)
        case table(Table)
    }

    var content: Content
    var height: CGFloat

    // MARK: Building

    /// nil: the row stays SwiftUI (math needs the web renderer).
    static func make(_ kind: ChatRow.Kind, id: String, expanded: Bool, environment: ChatNativeEnvironment) -> ChatNativeLayout? {
        // At accessibility sizes the SwiftUI rows stack and wrap (`ChatNativeEligibility`).
        guard !environment.category.isAccessibilityCategory else { return nil }
        let styles = NativeTextStyles(category: environment.category)
        let width = environment.width
        switch kind {
        case .sessionStart(let date, let earlier):
            let font = styles.font(.footnote)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSAttributedString(string: ChatRow.sessionLine(date, earlier: earlier),
                                          attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: paragraph])
            let size = measure(text, width: width)
            return ChatNativeLayout(content: .drawn(Drawn(texts: [Text(text: text, frame: CGRect(x: 0, y: 8, width: width, height: size.height))])),
                                    height: 8 + size.height + 20)
        case .block(_, let block):
            return make(block.kind, expanded: expanded, width: width, styles: styles, wrapCode: environment.wrapCode)
        default:
            return ChatNativeWidgets(width: width, styles: styles).make(kind, id: id, expanded: expanded)
        }
    }

    static func make(_ kind: MarkdownBlock.Kind, expanded: Bool, width: CGFloat, styles: NativeTextStyles, wrapCode: Bool) -> ChatNativeLayout? {
        let body = styles.font(.body)
        switch kind {
        case .paragraph(let source):
            if ChatInlineText.needsWeb(source) { return nil }
            let text = ChatInlineText.make(source, font: body, color: .label)
            let size = measure(text, width: width)
            return ChatNativeLayout(content: .drawn(Drawn(texts: [Text(text: text, frame: CGRect(x: 0, y: 0, width: width, height: size.height))])),
                                    height: size.height)
        case .heading(let level, let source):
            let font: UIFont = level == 1 ? styles.font(.title3, weight: .bold) : level == 2 ? styles.font(.headline) : styles.font(.subheadline, weight: .bold)
            let text = ChatInlineText.make(source, font: font, color: .label)
            let top: CGFloat = level <= 2 ? 6 : 2
            let size = measure(text, width: width)
            return ChatNativeLayout(content: .drawn(Drawn(texts: [Text(text: text, frame: CGRect(x: 0, y: top, width: width, height: size.height),
                                                                       isHeader: true)])),
                                    height: top + size.height)
        case .quote(let source):
            let text = ChatInlineText.make(source, font: body, color: .secondaryLabel)
            let size = measure(text, width: width - 15)
            return ChatNativeLayout(content: .drawn(Drawn(texts: [Text(text: text, frame: CGRect(x: 15, y: 0, width: width - 15, height: size.height))],
                                                          bars: [CGRect(x: 0, y: 0, width: 3, height: size.height)])),
                                    height: size.height)
        case .rule:
            let line = 1 / 3.0
            return ChatNativeLayout(content: .drawn(Drawn(rule: CGRect(x: 0, y: 4, width: width, height: line))), height: 8 + line)
        case .list(let list):
            return listLayout(list, width: width, styles: styles)
        case .code(let language, let code, _):
            return codeLayout(language: language, code: code, expanded: expanded, width: width, styles: styles, wrapCode: wrapCode)
        case .table(let table):
            return tableLayout(table, width: width, styles: styles)
        case .math:
            return nil
        }
    }

    /// `MarkdownListView`: rows 8 pt apart, a marker column at least 14 pt wide (trailing
    /// aligned, on the first baseline), 8 pt to the text, 20 pt per depth plus 4.
    private static func listLayout(_ list: MarkdownList, width: CGFloat, styles: NativeTextStyles) -> ChatNativeLayout? {
        let body = styles.font(.body)
        var drawn = Drawn()
        var y: CGFloat = 0
        for (index, item) in list.items.enumerated() {
            if ChatInlineText.needsWeb(item.text) { return nil }
            let lead = CGFloat(item.depth) * 20 + 4
            var markerWidth: CGFloat = 14
            if let checked = item.checked {
                let font = styles.font(.subheadline)
                let name = checked ? "checkmark.square.fill" : "square"
                let size = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(font: font))?.size ?? CGSize(width: 16, height: 16)
                markerWidth = max(14, size.width)
                // On the text's first line, centered on its x-height band like a baseline-aligned glyph.
                let lineMid = body.ascender - body.xHeight / 2
                drawn.symbols.append(Symbol(name: name, font: font, color: checked ? .cmuxMobileSuccess : .secondaryLabel,
                                            frame: CGRect(x: lead + markerWidth - size.width, y: y + lineMid - size.height / 2,
                                                          width: size.width, height: size.height)))
            } else {
                let markerFont = item.ordinal != nil ? UIFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular) : body
                let marker = NSAttributedString(string: item.ordinal.map { "\($0)." } ?? (item.depth == 0 ? "•" : "◦"),
                                                attributes: [.font: markerFont, .foregroundColor: UIColor.secondaryLabel])
                let size = measure(marker, width: .greatestFiniteMagnitude)
                markerWidth = max(14, size.width)
                drawn.texts.append(Text(text: marker, frame: CGRect(x: lead + markerWidth - size.width, y: y, width: size.width, height: size.height)))
            }
            let x = lead + markerWidth + 8
            let text = ChatInlineText.make(item.text, font: body, color: .label)
            let size = measure(text, width: max(width - x, 20))
            drawn.texts.append(Text(text: text, frame: CGRect(x: x, y: y, width: max(width - x, 20), height: size.height)))
            y += size.height
            if index < list.items.count - 1 { y += 8 }
        }
        return ChatNativeLayout(content: .drawn(drawn), height: y)
    }

    /// `CodeCard`: a 40 pt header (glyph, language, copy), mono code 4 pt under it with 16 pt
    /// sides and bottom, capped at 480 pt with "Show all N lines".
    private static func codeLayout(language: String?, code: String, expanded: Bool, width: CGFloat, styles: NativeTextStyles,
                                   wrapCode: Bool) -> ChatNativeLayout {
        let codeSize = styles.scaled(13, relativeTo: .footnote)
        let font = UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        let lang = language?.lowercased() ?? ""
        let body = codeText(code, language: lang, font: font, lineSpacing: codeSize * 0.46)
        let bodySize = measure(body, width: wrapCode ? max(width - 32, 20) : .greatestFiniteMagnitude)
        let lineCount = code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let maxHeight: CGFloat = 480
        let capped = !expanded && CGFloat(lineCount) * codeSize * 1.46 + 20 > maxHeight
        let scrollHeight = capped ? maxHeight - 40 : 4 + bodySize.height + 16
        let isShell = ["bash", "sh", "shell", "zsh", "console"].contains(lang)
        let symbol = lang == "diff" ? "plus.forwardslash.minus" : (isShell ? "terminal" : "chevron.left.forwardslash.chevron.right")
        let title = NSAttributedString(string: displayLanguage(language),
                                       attributes: [.font: styles.font(.footnote, weight: .medium), .foregroundColor: UIColor.secondaryLabel])
        let showAll = NSAttributedString(string: "Show all \(lineCount) lines",
                                         attributes: [.font: styles.font(.subheadline, weight: .semibold), .foregroundColor: UIColor.label])
        let card = Code(code: code, language: language, symbol: symbol, title: title, body: body, bodySize: bodySize, lineCount: lineCount,
                        capped: capped, cardHeight: 40 + scrollHeight, showAll: showAll)
        return ChatNativeLayout(content: .code(card), height: card.cardHeight)
    }

    private static func displayLanguage(_ language: String?) -> String {
        guard let language, !language.isEmpty else { return "Code" }
        let names = ["swift": "Swift", "py": "Python", "python": "Python", "ts": "TypeScript", "typescript": "TypeScript",
                     "js": "JavaScript", "javascript": "JavaScript", "rs": "Rust", "rust": "Rust", "sh": "Bash", "bash": "Bash",
                     "zsh": "Zsh", "diff": "Diff", "json": "JSON", "yaml": "YAML", "toml": "TOML", "go": "Go", "tsx": "TSX", "md": "Markdown"]
        return names[language.lowercased()] ?? language.capitalized
    }

    /// `CodeHighlightCache`'s colors: diff lines by their marker, else the syntax palette.
    static func codeText(_ code: String, language: String, font: UIFont, lineSpacing: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byCharWrapping
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        let output = NSMutableAttributedString()
        if language == "diff" {
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
        for piece in SyntaxHighlighter(language: language.isEmpty ? nil : language).pieces(code) {
            var attributes = base
            if let token = piece.token { attributes[.foregroundColor] = SyntaxHighlighter.uiColor(token) }
            output.append(NSAttributedString(string: piece.text, attributes: attributes))
        }
        return output
    }

    /// `MarkdownTableView`: cells 72...236 pt of text with 12/10 pt padding, a hairline between
    /// rows, 8 pt of room at each end, in a scroll area that bleeds to the screen edges.
    private static func tableLayout(_ table: MarkdownTable, width: CGFloat, styles: NativeTextStyles) -> ChatNativeLayout? {
        let font = styles.font(.subheadline)
        let bold = styles.font(.subheadline, weight: .semibold)
        let columns = table.columnCount
        let rows = [table.header] + table.rows
        var texts: [[NSAttributedString]] = []
        var sizes: [[CGSize]] = []
        var labelHeights: [Int: [Int: CGFloat]] = [:]
        var widths = Array(repeating: CGFloat(72), count: columns)
        for (r, row) in rows.enumerated() {
            var line: [NSAttributedString] = []
            var lineSizes: [CGSize] = []
            for c in 0..<columns {
                let source = c < row.count ? row[c] : ""
                if ChatInlineText.needsWeb(source) { return nil }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 5
                switch c < table.alignments.count ? table.alignments[c] : .leading {
                case .leading: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .trailing: paragraph.alignment = .right
                }
                let text = ChatInlineText.make(source, font: r == 0 ? bold : font, color: .label, paragraph: paragraph)
                let ideal = measure(text, width: .greatestFiniteMagnitude).width
                let cellWidth = min(max(ideal, 72), 236)
                let size = measure(text, width: cellWidth)
                widths[c] = max(widths[c], cellWidth)
                line.append(text)
                // The row's height as SwiftUI sets it: lines of the cell font's height (a monospaced
                // run such as `0` does not make its line taller), 5 pt between lines.
                let lines = lineCount(text, width: cellWidth)
                let base = ((r == 0 ? bold : font).lineHeight * 3).rounded(.up) / 3
                lineSizes.append(CGSize(width: cellWidth, height: CGFloat(lines) * base + CGFloat(lines - 1) * 5))
                labelHeights[r, default: [:]][c] = size.height
            }
            texts.append(line)
            sizes.append(lineSizes)
        }
        var cells: [Text] = []
        var rules: [CGRect] = []
        var y: CGFloat = 0
        let lead: CGFloat = 8
        let total = widths.reduce(0) { $0 + $1 + 24 }
        let hairline = 1 / 3.0
        for (r, line) in texts.enumerated() {
            if r > 0 {
                rules.append(CGRect(x: lead, y: y, width: total, height: hairline))
                y += hairline
            }
            let rowHeight = (sizes[r].map(\.height).max() ?? 0) + 20
            var x = lead
            for (c, text) in line.enumerated() {
                // Each cell's text is as wide as its column, so the column's alignment applies across it.
                cells.append(Text(text: text, frame: CGRect(x: x + 12, y: y + 10, width: widths[c],
                                                            height: max(sizes[r][c].height, labelHeights[r]?[c] ?? 0))))
                x += widths[c] + 24
            }
            y += rowHeight
        }
        return ChatNativeLayout(content: .table(Table(cells: cells, rules: rules, contentSize: CGSize(width: total + lead * 2, height: y),
                                                      plainText: table.plainText)),
                                height: y)
    }

    /// The lines `text` takes at `width` (TextKit).
    static func lineCount(_ text: NSAttributedString, width: CGFloat) -> Int {
        guard text.length > 0 else { return 1 }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
        return max(lines, 1)
    }

    /// Text laid out at `width` as UILabel draws it, rounded up to the pixel grid.
    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        guard text.length > 0 else { return .zero }
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: (rect.width * 3).rounded(.up) / 3, height: (rect.height * 3).rounded(.up) / 3)
    }
}

/// Inline markdown to UIKit text with `InlineMarkdownCache`'s look: bold, italic, code in the
/// monospaced variant of the font on the fill color, strikethrough, links underlined in the text
/// color, and file paths in code linked (the chat opens their preview). 5 pt between lines.
enum ChatInlineText {
    static func make(_ source: String, font: UIFont, color: UIColor, paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
        let style: NSParagraphStyle = paragraph ?? {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            return style
        }()
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: style]
            var traits: UIFontDescriptor.SymbolicTraits = []
            var mono = false
            var link = run.link
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if intent.contains(.code) {
                    mono = true
                    attributes[.backgroundColor] = UIColor.cmuxMobileFill
                    if link == nil, let path = MarkdownFilePath(text)?.url { link = path }
                }
            }
            var runFont = font
            if mono {
                let weight = (font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
                runFont = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: UIFont.Weight(weight ?? 0))
            }
            if !traits.isEmpty, let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits)) {
                runFont = UIFont(descriptor: descriptor, size: runFont.pointSize)
            }
            attributes[.font] = runFont
            if let link {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = UIColor.label
                attributes[NativeMarkdownLayout.linkKey] = link
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        return output
    }

    /// Inline math goes to the web renderer (the SwiftUI row draws it).
    static func needsWeb(_ text: String) -> Bool {
        MarkdownDocument(parsing: text).needsWebRenderer
    }
}
#endif

#if os(iOS)
/// The transcript's native row layouts, by row id: kept while the row's revision, its
/// expanded state and the environment stay the same. Rows are laid out in batches on a
/// background task (prefetch, or rows whose height is still an estimate); a row needed on
/// screen before its batch lands is laid out on the spot.
@MainActor
final class ChatNativeLayouts {
    struct Job: Sendable {
        var id: String
        var revision: Int
        var kind: ChatRow.Kind
        var expanded: Bool
    }

    private struct Entry {
        var revision: Int
        var expanded: Bool
        /// nil: the row stays SwiftUI (math).
        var layout: ChatNativeLayout?
    }

    var environment: ChatNativeEnvironment? {
        didSet {
            guard environment != oldValue else { return }
            entries = [:]
            queued = [:]
            generation &+= 1
        }
    }
    private var entries: [String: Entry] = [:]
    /// Rows with a layout on its way, and for which revision, state and environment: a
    /// newer revision or a new environment queues the row again instead of waiting for a
    /// batch whose result will be discarded.
    private struct Queued: Equatable {
        var generation: Int
        var revision: Int
        var expanded: Bool
    }
    private var queued: [String: Queued] = [:]
    private var generation = 0
    /// Rows laid out on the main thread / off it (tests and the rig's log).
    private(set) var madeNow = 0
    private(set) var madeOffMain = 0

    func reset() {
        entries = [:]
        queued = [:]
        generation &+= 1
    }

    func retain(_ ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    func has(_ id: String, revision: Int, expanded: Bool) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.revision == revision && entry.expanded == expanded
    }

    /// The row's height if it is laid out natively (nil when unknown or SwiftUI).
    func height(_ id: String, revision: Int, expanded: Bool) -> CGFloat? {
        guard let entry = entries[id], entry.revision == revision, entry.expanded == expanded else { return nil }
        return entry.layout?.height
    }

    /// The row's layout, made here if missing (nil: SwiftUI, or no environment yet).
    @discardableResult
    func makeNow(_ row: ChatRow, revision: Int, expanded: Bool) -> ChatNativeLayout? {
        if let entry = entries[row.id], entry.revision == revision, entry.expanded == expanded { return entry.layout }
        guard let environment else { return nil }
        madeNow += 1
        #if DEBUG
        let start = CACurrentMediaTime()
        defer { ChatRowCost.add(row.costKind, "sync", CACurrentMediaTime() - start) }
        #endif
        let layout = ChatNativeLayout.make(row.kind, id: row.id, expanded: expanded, environment: environment)
        entries[row.id] = Entry(revision: revision, expanded: expanded, layout: layout)
        return layout
    }

    /// Lays out `jobs` off the main thread; `ready` gets the ids that landed (still current).
    func prepare(_ jobs: [Job], urgent: Bool, ready: @escaping @MainActor ([String]) -> Void) {
        guard let environment else { return }
        let generation = generation
        let fresh = jobs.filter { queued[$0.id] != Queued(generation: generation, revision: $0.revision, expanded: $0.expanded) }
        guard !fresh.isEmpty else { return }
        for job in fresh { queued[job.id] = Queued(generation: generation, revision: job.revision, expanded: job.expanded) }
        Task { [weak self] in
            let made = await Task.detached(priority: urgent ? .userInitiated : .utility) {
                fresh.map { ($0, ChatNativeLayout.make($0.kind, id: $0.id, expanded: $0.expanded, environment: environment)) }
            }.value
            guard let self else { return }
            for job in fresh where self.queued[job.id] == Queued(generation: generation, revision: job.revision, expanded: job.expanded) {
                self.queued[job.id] = nil
            }
            guard self.generation == generation else { return }
            var landed: [String] = []
            for (job, layout) in made where self.entries[job.id].map({ $0.revision < job.revision || $0.expanded != job.expanded }) ?? true {
                self.entries[job.id] = Entry(revision: job.revision, expanded: job.expanded, layout: layout)
                self.madeOffMain += 1
                landed.append(job.id)
            }
            if !landed.isEmpty { ready(landed) }
        }
    }
}
#endif

#if os(iOS)
/// SF Symbol images by name and font, made once (rows draw the same few symbols over and over).
enum ChatSymbols {
    // concurrency-allow: NSCache is documented thread-safe; layouts read it off the main thread.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func image(_ name: String, _ font: UIFont) -> UIImage? {
        let key = "\(name)|\(font.pointSize)|\(font.fontName)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(font: font)) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
#endif
