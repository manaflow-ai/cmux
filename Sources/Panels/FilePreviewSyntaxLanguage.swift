import Foundation

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
