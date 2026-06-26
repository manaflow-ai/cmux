import AppKit
import Foundation

/// Classification produced by ``FilePreviewSyntaxTokenizer`` for a run of source
/// text. Only spans that get a non-default color are emitted; plain identifiers,
/// whitespace, and punctuation are left to the editor's base foreground color.
enum FilePreviewSyntaxTokenKind: Equatable, Sendable {
    case keyword
    case type
    case string
    case number
    case comment
    case function
    case attribute
}

/// A colored span of source text, expressed as a UTF-16 ``NSRange`` so it can be
/// applied directly to an `NSTextStorage` / `NSLayoutManager`.
struct FilePreviewSyntaxToken: Equatable, Sendable {
    let range: NSRange
    let kind: FilePreviewSyntaxTokenKind
}

/// A language the built-in file preview can syntax highlight. Detected from the
/// file extension (and, for a few extensionless files, the filename). The
/// per-language scanning parameters live in ``FilePreviewSyntaxGrammar``.
enum FilePreviewSyntaxLanguage: String, CaseIterable, Sendable {
    case swift
    case cFamily
    case cpp
    case objc
    case java
    case kotlin
    case csharp
    case javascript
    case typescript
    case python
    case ruby
    case go
    case rust
    case php
    case shell
    case sql
    case css
    case json
    case yaml
    case toml
    case ini

    /// Resolves the highlighting language for a file URL, or `nil` when the file
    /// type has no grammar (it then renders as plain text, as before).
    static func detect(for url: URL) -> FilePreviewSyntaxLanguage? {
        let filename = url.lastPathComponent.lowercased()
        if let byName = languagesByFilename[filename] {
            return byName
        }
        let ext = url.pathExtension.lowercased()
        return languagesByExtension[ext]
    }

    private static let languagesByFilename: [String: FilePreviewSyntaxLanguage] = [
        ".zshrc": .shell,
        ".bashrc": .shell,
        ".bash_profile": .shell,
        ".profile": .shell,
        ".npmrc": .ini,
        ".gitconfig": .ini,
        ".editorconfig": .ini,
        "gemfile": .ruby,
        "podfile": .ruby,
        "rakefile": .ruby
    ]

    private static let languagesByExtension: [String: FilePreviewSyntaxLanguage] = [
        "swift": .swift,
        "c": .cFamily,
        "h": .cFamily,
        "cc": .cpp,
        "cpp": .cpp,
        "cxx": .cpp,
        "hpp": .cpp,
        "hh": .cpp,
        "hxx": .cpp,
        "m": .objc,
        "mm": .objc,
        "java": .java,
        "kt": .kotlin,
        "kts": .kotlin,
        "cs": .csharp,
        "js": .javascript,
        "jsx": .javascript,
        "mjs": .javascript,
        "cjs": .javascript,
        "ts": .typescript,
        "tsx": .typescript,
        "mts": .typescript,
        "cts": .typescript,
        "py": .python,
        "pyi": .python,
        "rb": .ruby,
        "go": .go,
        "rs": .rust,
        "php": .php,
        "sh": .shell,
        "bash": .shell,
        "zsh": .shell,
        "fish": .shell,
        "sql": .sql,
        "css": .css,
        "scss": .css,
        "less": .css,
        "json": .json,
        "jsonc": .json,
        "yaml": .yaml,
        "yml": .yaml,
        "toml": .toml,
        "ini": .ini,
        "cfg": .ini,
        "conf": .ini
    ]

    var grammar: FilePreviewSyntaxGrammar {
        FilePreviewSyntaxGrammar.grammar(for: self)
    }
}

/// Foreground colors for each token kind, tuned for dark and light editor
/// backgrounds. The base (uncolored) text keeps the editor's own foreground.
/// Built and consumed entirely on the main thread, so it does not need to be
/// `Sendable` (which `NSColor` is not).
struct FilePreviewSyntaxTheme {
    let keyword: NSColor
    let type: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let function: NSColor
    let attribute: NSColor

    func color(for kind: FilePreviewSyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .type: return type
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .function: return function
        case .attribute: return attribute
        }
    }

    /// Decides whether to use the dark palette by inspecting the editor's
    /// foreground color: light text means a dark background, and vice versa.
    /// Sidesteps the `usesClearContentBackground` case where the content
    /// background color is `.clear` and carries no usable luminance.
    static func prefersDarkPalette(foreground: NSColor) -> Bool {
        guard let rgb = foreground.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance >= 0.5
    }

    static func theme(prefersDark: Bool) -> FilePreviewSyntaxTheme {
        prefersDark ? .dark : .light
    }

    static let dark = FilePreviewSyntaxTheme(
        keyword: NSColor(srgbRed: 0.98, green: 0.47, blue: 0.66, alpha: 1.0),
        type: NSColor(srgbRed: 0.40, green: 0.85, blue: 0.94, alpha: 1.0),
        string: NSColor(srgbRed: 0.60, green: 0.84, blue: 0.55, alpha: 1.0),
        number: NSColor(srgbRed: 0.95, green: 0.71, blue: 0.49, alpha: 1.0),
        comment: NSColor(srgbRed: 0.50, green: 0.56, blue: 0.62, alpha: 1.0),
        function: NSColor(srgbRed: 0.55, green: 0.76, blue: 0.99, alpha: 1.0),
        attribute: NSColor(srgbRed: 0.85, green: 0.69, blue: 0.99, alpha: 1.0)
    )

    static let light = FilePreviewSyntaxTheme(
        keyword: NSColor(srgbRed: 0.66, green: 0.13, blue: 0.44, alpha: 1.0),
        type: NSColor(srgbRed: 0.13, green: 0.42, blue: 0.55, alpha: 1.0),
        string: NSColor(srgbRed: 0.13, green: 0.50, blue: 0.20, alpha: 1.0),
        number: NSColor(srgbRed: 0.62, green: 0.36, blue: 0.05, alpha: 1.0),
        comment: NSColor(srgbRed: 0.40, green: 0.46, blue: 0.52, alpha: 1.0),
        function: NSColor(srgbRed: 0.15, green: 0.36, blue: 0.78, alpha: 1.0),
        attribute: NSColor(srgbRed: 0.45, green: 0.27, blue: 0.66, alpha: 1.0)
    )
}
