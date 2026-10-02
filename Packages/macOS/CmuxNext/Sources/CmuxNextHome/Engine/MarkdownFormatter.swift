public import CoreGraphics
import CoreText
import Foundation

/// A safe Markdown subset for other participants' messages (home.md section 6):
/// fenced code blocks, headings, bullet and numbered lists, block quotes, and
/// inline bold, italic, code and links. Nothing is fetched or executed: link
/// targets are kept only as a `link` attribute, images are not loaded.
///
/// Every line keeps the transcript's fixed line height, so measurement,
/// estimates and drawing agree. Styling uses the bubble's own text color: code
/// uses the monospaced face, links are underlined in the text color (never
/// blue), quotes and list markers use the text color at reduced alpha.
/// Pure function of (text, font size, line height, color): safe off the main
/// actor and cacheable by message version and width like plain text.
nonisolated enum MarkdownFormatter {
    /// The attribute that carries a link target (for hit-testing).
    static let linkKey = NSAttributedString.Key("cmux.home.link")

    struct Style: OptionSet {
        let rawValue: Int
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let code = Style(rawValue: 4)
        static let muted = Style(rawValue: 8)
        static let underline = Style(rawValue: 16)
    }

    static func attributed(_ text: String, fontSize: CGFloat, lineHeight: CGFloat, color: CGColor?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let fonts = Fonts(size: fontSize)
        let paragraph = TextFormatter.paragraph(lineHeight: lineHeight)
        func append(_ string: String, _ style: Style, link: String? = nil) {
            guard !string.isEmpty else { return }
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): fonts.font(for: style),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ]
            if let color {
                let alpha = style.contains(.muted) ? 0.62 : 1.0
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] =
                    alpha < 1 ? (color.copy(alpha: color.alpha * alpha) ?? color) : color
            }
            if style.contains(.underline) {
                attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
            }
            if let link { attributes[linkKey] = link }
            out.append(NSAttributedString(string: string, attributes: attributes))
        }
        var inFence = false
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if index > 0, out.length > 0 { append("\n", []) }
            if inFence {
                append(line.isEmpty ? " " : line, .code)
                continue
            }
            let block = Block(line)
            if let marker = block.marker { append(marker, .muted) }
            for run in MarkdownInline.runs(block.content) { append(run.text, run.style.union(block.style), link: run.link) }
        }
        return out
    }

    /// The fonts of one size, created once per call.
    struct Fonts {
        let regular: CTFont, bold: CTFont, italic: CTFont, boldItalic: CTFont, code: CTFont

        init(size: CGFloat) {
            regular = TextFormatter.font(size: size)
            bold = TextFormatter.font(size: size, emphasized: true)
            italic = CTFontCreateCopyWithSymbolicTraits(regular, size, nil, .traitItalic, .traitItalic) ?? regular
            boldItalic = CTFontCreateCopyWithSymbolicTraits(bold, size, nil, .traitItalic, .traitItalic) ?? bold
            code = CTFontCreateUIFontForLanguage(.userFixedPitch, size * 0.94, nil) ?? regular
        }

        func font(for style: Style) -> CTFont {
            if style.contains(.code) { return code }
            switch (style.contains(.bold), style.contains(.italic)) {
            case (true, true): return boldItalic
            case (true, false): return bold
            case (false, true): return italic
            case (false, false): return regular
            }
        }
    }

    /// One line's block syntax: heading, list item or quote.
    struct Block {
        var marker: String?
        var content: Substring
        var style: Style = []

        init(_ line: String) {
            var rest = Substring(line)
            let indent = rest.prefix { $0 == " " }
            rest = rest.dropFirst(indent.count)
            let hashes = rest.prefix { $0 == "#" }
            if (1...6).contains(hashes.count), rest.dropFirst(hashes.count).first == " " {
                content = rest.dropFirst(hashes.count + 1)
                style = .bold
                return
            }
            if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
                marker = String(repeating: " ", count: min(indent.count, 8)) + "•  "
                content = rest.dropFirst(2)
                return
            }
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if (1...3).contains(digits.count), rest.dropFirst(digits.count).hasPrefix(". ") {
                marker = String(repeating: " ", count: min(indent.count, 8)) + digits + ".  "
                content = rest.dropFirst(digits.count + 2)
                return
            }
            if rest.first == ">" {
                marker = "▎ "
                content = rest.dropFirst().drop { $0 == " " }
                style = .muted
                return
            }
            content = Substring(line)
        }
    }
}
