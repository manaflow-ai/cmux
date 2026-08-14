/// Resolves a syntax language from a standalone file's name or extension.
public struct FilePreviewSyntaxLanguageResolver: Sendable {
    /// Creates a filename-based language resolver.
    public init() {}

    /// Returns the syntax language for `filename`, or `nil` when no grammar is available.
    ///
    /// Matching is case-insensitive and includes common extensionless config and build files.
    ///
    /// - Parameter filename: A basename such as `main.swift` or `.zshrc`.
    /// - Returns: The matching language family, if recognized.
    public func language(forFilename filename: String) -> FilePreviewSyntaxLanguage? {
        let normalized = filename.lowercased()
        switch normalized {
        case ".zshrc", ".bashrc", ".bash_profile", ".profile", "dockerfile", "makefile":
            return .shell
        case ".npmrc", ".gitconfig", ".editorconfig", ".env":
            return .ini
        case "gemfile", "podfile", "rakefile":
            return .ruby
        default:
            break
        }

        guard let extensionSeparator = normalized.lastIndex(of: ".") else {
            return nil
        }
        let fileExtension = String(normalized[normalized.index(after: extensionSeparator)...])
        switch fileExtension {
        case "swift": return .swift
        case "c", "h": return .cFamily
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx": return .cpp
        case "m", "mm": return .objc
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "cs": return .csharp
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyi", "pyw": return .python
        case "rb": return .ruby
        case "go": return .go
        case "rs": return .rust
        case "php", "php3", "php4", "php5", "phtml": return .php
        case "sh", "bash", "zsh", "fish": return .shell
        case "sql": return .sql
        case "css", "scss", "sass", "less": return .css
        case "json", "jsonc", "geojson": return .json
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "ini", "cfg", "conf", "properties": return .ini
        default: return nil
        }
    }
}
