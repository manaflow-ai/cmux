import AppKit
import CmuxNextDesign

/// One block of a README: a heading, a paragraph or list item, or a code block, with its inline runs.
nonisolated struct AppStoreMarkdownBlock: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case heading(Int)
        case paragraph
        case bullet
        case code
    }

    var kind: Kind
    /// The inline runs (bold, italic, code, links) as Foundation's Markdown parser reads them.
    var text: AttributedString

    /// Splits `markdown` into blocks (headings, paragraphs, list items, fenced code). Plain Swift, no
    /// AppKit: the store parses off the main actor and only draws on it. HTML and images stay as text.
    static func parse(_ markdown: String) -> [AppStoreMarkdownBlock] {
        var blocks: [AppStoreMarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func inline(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        }
        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(AppStoreMarkdownBlock(kind: .paragraph, text: inline(paragraph.joined(separator: " "))))
            paragraph = []
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false).prefix(2000) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if let lines = code {
                    blocks.append(AppStoreMarkdownBlock(kind: .code, text: AttributedString(lines.joined(separator: "\n"))))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let level = Self.headingLevel(trimmed) {
                flush()
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(AppStoreMarkdownBlock(kind: .heading(level), text: inline(title)))
            } else if let item = Self.listItem(trimmed) {
                flush()
                blocks.append(AppStoreMarkdownBlock(kind: .bullet, text: inline(item)))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(AppStoreMarkdownBlock(kind: .code, text: AttributedString(lines.joined(separator: "\n")))) }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return String(line.dropFirst(2)) }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return String(line.dropFirst(digits.count + 2)) }
        return nil
    }
}

/// A README drawn natively: the type scale's fonts and the theme's inks, selectable, links opening in
/// cmux's browser. Read-only; it sizes to its text at the width it is given.
final class AppStoreMarkdownView: NSTextView, NSTextViewDelegate {
    private let openLink: @MainActor (URL) -> Void
    private let fixedWidth: CGFloat
    private let blocks: [AppStoreMarkdownBlock]

    init(blocks: [AppStoreMarkdownBlock], width: CGFloat, openLink: @escaping @MainActor (URL) -> Void) {
        self.openLink = openLink
        self.blocks = blocks
        fixedWidth = width
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10), textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = true
        textContainerInset = .zero
        translatesAutoresizingMaskIntoConstraints = false
        delegate = self
        applyText()
        widthAnchor.constraint(equalToConstant: width).isActive = true
        setAccessibilityIdentifier("cmux.appStore.listing.readme")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        openLink = { _ in }
        blocks = []
        fixedWidth = frameRect.width
        super.init(frame: frameRect, textContainer: container)
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return NSSize(width: fixedWidth, height: 0) }
        layoutManager.ensureLayout(for: textContainer)
        return NSSize(width: fixedWidth, height: ceil(layoutManager.usedRect(for: textContainer).height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyText()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == "https" || url.scheme == "http" else { return true }
        openLink(url)
        return true
    }

    private func applyText() {
        let text = performWithTheme { Self.render(blocks) }
        textStorage?.setAttributedString(text)
        performWithTheme {
            linkTextAttributes = [.foregroundColor: Palette.focusRing, .underlineStyle: NSUnderlineStyle.single.rawValue]
            selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        }
        invalidateIntrinsicContentSize()
    }

    /// The blocks as one attributed string, in the current theme scope.
    private static func render(_ blocks: [AppStoreMarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let base: NSFont
            let ink: NSColor
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = Metrics.space2
            switch block.kind {
            case .heading(let level):
                base = Typography.system(size: level <= 1 ? TypeScale.heading : level == 2 ? TypeScale.title : TypeScale.body,
                                         weight: TypeScale.emphasis)
                ink = Palette.textPrimary
                style.paragraphSpacingBefore = index == 0 ? 0 : Metrics.space3
            case .paragraph:
                base = Typography.system(size: TypeScale.body)
                ink = Palette.textPrimary
            case .bullet:
                base = Typography.system(size: TypeScale.body)
                ink = Palette.textPrimary
                style.headIndent = Metrics.space4
                style.firstLineHeadIndent = 0
                style.paragraphSpacing = Metrics.space1
            case .code:
                base = Typography.system(.monospaced, size: TypeScale.detail)
                ink = Palette.textSecondary
                style.headIndent = Metrics.space3
                style.firstLineHeadIndent = Metrics.space3
            }
            let line = NSMutableAttributedString()
            if block.kind == .bullet { line.append(NSAttributedString(string: "•\t")) }
            for run in block.text.runs {
                let piece = String(block.text[run.range].characters)
                var font = base
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.code) { font = Typography.system(.monospaced, size: TypeScale.detail) }
                    else if intent.contains(.stronglyEmphasized) { font = Typography.system(size: base.pointSize, weight: TypeScale.emphasis) }
                    else if intent.contains(.emphasized) { font = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) }
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: font]
                if let link = run.link { attributes[.link] = link }
                line.append(NSAttributedString(string: piece, attributes: attributes))
            }
            line.addAttributes([.paragraphStyle: style, .foregroundColor: ink], range: NSRange(location: 0, length: line.length))
            line.enumerateAttribute(.font, in: NSRange(location: 0, length: line.length)) { value, range, _ in
                if value == nil { line.addAttribute(.font, value: base, range: range) }
            }
            if index < blocks.count - 1 { line.append(NSAttributedString(string: "\n", attributes: [.font: base, .paragraphStyle: style])) }
            out.append(line)
        }
        return out
    }
}
