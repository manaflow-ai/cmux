#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// Inline markdown (bold, italic, code, links, strikethrough) to a styled
/// `AttributedString`, following SPEC 2.2: inline code mono on `fill`, links
/// underlined in `label` (no blue). Results are cached by source text since
/// committed blocks never change and the streaming tail changes every tick.
@MainActor
public final class InlineMarkdownCache {
    public static let shared = InlineMarkdownCache()
    private var cache: [String: AttributedString] = [:]
    private var order: [String] = []
    private let limit = 800

    public func attributed(_ source: String, baseFont: Font = .body) -> AttributedString {
        let key = source
        if let hit = cache[key] { return hit }
        let value = Self.render(source)
        cache[key] = value
        order.append(key)
        if order.count > limit {
            cache[order.removeFirst()] = nil
        }
        return value
    }

    /// Preserve the parsed runs (including scheme-less file links) when drawing them with UIKit.
    func labelText(_ source: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let parsed = attributed(source)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            // Code starts from the system monospaced font at the row's size and weight: a text
            // style's descriptor (`preferredFont`) ignores `withDesign(.monospaced)` once its traits
            // are set, so a code span in a table cell drew in the proportional face (#52600's test).
            let descriptor = intent.contains(.code) ? Self.monospaced(like: font).fontDescriptor : font.fontDescriptor
            var traits = descriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            let runFont = UIFont(descriptor: descriptor.withSymbolicTraits(traits) ?? descriptor, size: font.pointSize)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if intent.contains(.code) { attributes[.backgroundColor] = UIColor.cmuxMobileFill }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link {
                attributes[NativeMarkdownLayout.linkKey] = url
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = UIColor.label
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }

    /// The system monospaced font at `font`'s size and weight.
    private static func monospaced(like font: UIFont) -> UIFont {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? CGFloat).map { UIFont.Weight(rawValue: $0) } ?? .regular
        return UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: weight)
    }

    static func render(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var result = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent else {
                if run.link != nil {
                    result[run.range].underlineStyle = .single
                    result[run.range].foregroundColor = .primary
                }
                continue
            }
            if intent.contains(.code) {
                // No explicit font: Text draws the code intent in the
                // monospaced variant of the surrounding font, so code in a
                // plan step or table cell matches its text size.
                result[run.range].backgroundColor = Color.cmuxMobileFill
                // A file the agent names in code (`src/app.swift:12`) opens its
                // preview: a scheme-less link the chat's openURL handles.
                if run.link == nil, let link = MarkdownFilePath(String(result[run.range].characters))?.url {
                    result[run.range].link = link
                    result[run.range].underlineStyle = .single
                    result[run.range].foregroundColor = .primary
                    continue
                }
            }
            if run.link != nil {
                result[run.range].underlineStyle = .single
                result[run.range].foregroundColor = .primary
            }
        }
        return result
    }
}

/// Inline code that names a file: a path with a folder or a known file
/// extension, an optional `:line`, no spaces, not a URL.
public struct MarkdownFilePath: Equatable, Sendable {
    public let path: String

    static let pattern = try? NSRegularExpression(pattern: #"^(?:~|\.{1,2})?/?(?:[A-Za-z0-9_.@+\-]+/)*[A-Za-z0-9_@+\-][A-Za-z0-9_.@+\-]*\.([A-Za-z][A-Za-z0-9]{0,7})(?::\d+(?::\d+)?)?$"#)
    /// Extensions that make a bare name (no folder) a file: `README.md`, `main.swift`.
    static let fileExtensions: Set<String> = [
        "swift", "rs", "zig", "c", "h", "m", "mm", "cpp", "hpp", "go", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "sh", "zsh",
        "toml", "json", "yml", "yaml", "css", "scss", "sql", "rb", "java", "kt", "md", "markdown", "txt", "log", "csv", "html", "htm",
        "svg", "png", "jpg", "jpeg", "gif", "heic", "webp", "mp4", "mov", "m4v", "webm", "m4a", "mp3", "wav", "pdf", "docx", "xlsx",
        "pptx", "pages", "numbers", "keynote", "rtf", "xml", "plist", "lock", "diff", "patch", "proto", "graphql", "vue", "svelte",
    ]

    public init?(_ text: String) {
        guard text.count <= 300, !text.contains("://"), let pattern = Self.pattern,
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let extRange = Range(match.range(at: 1), in: text) else { return nil }
        let ext = text[extRange].lowercased()
        // `console.log`, `res.json`, `self.m`: a bare name with these reads as code, not a file.
        let ambiguous: Set<String> = ["log", "json", "m", "h", "c", "rs", "go", "py", "js", "ts", "css", "lock", "xml"]
        guard text.contains("/") || (Self.fileExtensions.contains(ext) && !ambiguous.contains(ext)) else { return nil }
        path = text
    }

    /// The link the chat opens (no scheme: a file reference, not a web page).
    public var url: URL? {
        URL(string: path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }
}

/// Inline text view used by every block.
struct InlineText: View {
    let source: String
    var style: UIFont.TextStyle = .body
    var weight: UIFont.Weight?
    var color: UIColor = .label
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
        let styles = NativeTextStyles(category: UIContentSizeCategory(typeSize))
        let font = weight.map { styles.font(style, weight: $0) } ?? styles.font(style)
        SelectableText(InlineMarkdownCache.shared.labelText(source, font: font, color: color))
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
