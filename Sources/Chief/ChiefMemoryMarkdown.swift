import AppKit

/// Renders a small memory file (person.md, instructions.md) as an attributed
/// string for the memory sheet's reading view: headings, bullet and numbered
/// lists, quotes, fenced code, paragraphs, and inline bold, italic, code and
/// links (Foundation's Markdown parser, inline syntax, per line).
///
/// The Markdown viewer panel (`MarkdownPanelView`) renders through a web view
/// bound to a `MarkdownPanel` and a workspace; these files are a few lines,
/// so a native text view keeps the sheet light and selectable.
enum ChiefMemoryMarkdown {
    struct Style {
        var text: NSColor = .labelColor
        var secondary: NSColor = .secondaryLabelColor
        var bodySize: CGFloat = 13
    }

    static func render(_ markdown: String, style: Style = Style()) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var inFence = false
        var previousBlank = true
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                append(out, rawLine, font: .monospacedSystemFont(ofSize: style.bodySize - 1, weight: .regular),
                       color: style.text, paragraph: paragraph(indent: 12, spacing: 0))
                previousBlank = false
                continue
            }
            if line.isEmpty {
                if !previousBlank { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])) }
                previousBlank = true
                continue
            }
            previousBlank = false
            if let level = headingLevel(line) {
                let sizes: [CGFloat] = [style.bodySize + 7, style.bodySize + 4, style.bodySize + 2]
                let size = sizes[min(level, sizes.count) - 1]
                appendInline(out, String(line.dropFirst(level + 1)), size: size, weight: .semibold,
                             color: style.text, paragraph: paragraph(indent: 0, spacing: 6, before: 6))
            } else if let item = bulletItem(line) {
                appendInline(out, "•\t" + item, size: style.bodySize, weight: .regular, color: style.text,
                             paragraph: paragraph(indent: 16, spacing: 4, hanging: true))
            } else if let (number, item) = numberedItem(line) {
                appendInline(out, "\(number).\t" + item, size: style.bodySize, weight: .regular, color: style.text,
                             paragraph: paragraph(indent: 20, spacing: 4, hanging: true))
            } else if line.hasPrefix(">") {
                appendInline(out, String(line.dropFirst()).trimmingCharacters(in: .whitespaces), size: style.bodySize,
                             weight: .regular, color: style.secondary, paragraph: paragraph(indent: 12, spacing: 4))
            } else {
                appendInline(out, line, size: style.bodySize, weight: .regular, color: style.text,
                             paragraph: paragraph(indent: 0, spacing: 6))
            }
        }
        // No trailing newline: the text view's height ends at the last line.
        while out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    // MARK: Blocks

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            var item = String(line.dropFirst(2))
            if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) }
            if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") { item = "☑ " + item.dropFirst(4) }
            return item
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }

    private static func paragraph(indent: CGFloat, spacing: CGFloat, before: CGFloat = 0,
                                  hanging: Bool = false) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.lineSpacing = 2
        if hanging {
            style.firstLineHeadIndent = indent - 12
            style.headIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        } else {
            style.firstLineHeadIndent = indent
            style.headIndent = indent
        }
        return style
    }

    // MARK: Inline

    private static func append(_ out: NSMutableAttributedString, _ text: String, font: NSFont, color: NSColor,
                               paragraph: NSParagraphStyle) {
        out.append(NSAttributedString(string: text + "\n",
                                      attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
    }

    private static func appendInline(_ out: NSMutableAttributedString, _ text: String, size: CGFloat,
                                     weight: NSFont.Weight, color: NSColor, paragraph: NSParagraphStyle) {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            append(out, text, font: base, color: color, paragraph: paragraph)
            return
        }
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var font = base
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: size - 1, weight: weight)
                    attributes[.backgroundColor] = color.withAlphaComponent(0.08)
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attributes[.link] = link
            }
            attributes[.font] = font
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: base, .paragraphStyle: paragraph]))
    }
}
