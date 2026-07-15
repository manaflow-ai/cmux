@preconcurrency import Highlighter
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Actor-isolated HighlighterSwift adapter using GitHub light and dark themes.
public actor HighlighterSwiftCodeHighlighter: CodeHighlighting {
    private var engines: [DiffColorScheme: Highlighter] = [:]

    /// Creates a lazily initialized HighlighterSwift adapter.
    public init() {}

    /// Highlights one source line on this actor's executor.
    /// - Parameters:
    ///   - line: Plain source text.
    ///   - language: Highlight.js language identifier, when known.
    ///   - colorScheme: Appearance whose GitHub theme should be used.
    /// - Returns: Platform-neutral foreground-color runs.
    public func highlight(
        line: String,
        language: String?,
        colorScheme: DiffColorScheme
    ) async -> HighlightedCode? {
        guard let engine = engine(for: colorScheme),
              let attributed = engine.highlight(line, as: language) else {
            return nil
        }
        var spans: [CodeHighlightSpan] = []
        var location = 0
        while location < attributed.length {
            var range = NSRange(location: location, length: 0)
            let attributes = attributed.attributes(at: location, effectiveRange: &range)
            let text = attributed.attributedSubstring(from: range).string
            spans.append(CodeHighlightSpan(
                text: text,
                foreground: color(from: attributes[.foregroundColor])
            ))
            location = NSMaxRange(range)
        }
        return HighlightedCode(spans: spans)
    }

    private func engine(for colorScheme: DiffColorScheme) -> Highlighter? {
        if let existing = engines[colorScheme] { return existing }
        guard let created = Highlighter() else { return nil }
        let theme = colorScheme == .dark ? "github-dark" : "github"
        guard created.setTheme(theme) else { return nil }
        engines[colorScheme] = created
        return created
    }

    private func color(from value: Any?) -> CodeHighlightColor? {
        #if canImport(UIKit)
        guard let color = value as? UIColor else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return CodeHighlightColor(
            red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha)
        )
        #elseif canImport(AppKit)
        guard let color = (value as? NSColor)?.usingColorSpace(.deviceRGB) else { return nil }
        return CodeHighlightColor(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
        #else
        return nil
        #endif
    }
}
