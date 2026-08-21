import Foundation

/// Syntax family inferred from a file name for the editable file preview.
enum FilePreviewSyntaxLanguage: String, Equatable, Sendable {
    case cFamily
    case configuration
    case css
    case go
    case html
    case java
    case javascript
    case json
    case kotlin
    case markdown
    case php
    case plainText
    case python
    case ruby
    case rust
    case shell
    case sql
    case swift
    case toml
    case typescript
    case yaml

    init(fileURL: URL) {
        let fileName = fileURL.lastPathComponent.lowercased()
        let pathExtension = fileURL.pathExtension.lowercased()

        if fileName == "dockerfile" || fileName.hasPrefix("dockerfile.") {
            self = .shell
            return
        }
        if fileName == "makefile" || fileName.hasPrefix("makefile.") {
            self = .shell
            return
        }
        if fileName == ".env" || fileName.hasPrefix(".env.") {
            self = .configuration
            return
        }

        switch pathExtension {
        case "swift": self = .swift
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "ts", "tsx", "mts", "cts": self = .typescript
        case "py", "pyw": self = .python
        case "sh", "bash", "zsh", "fish": self = .shell
        case "json", "jsonc": self = .json
        case "html", "htm", "xml", "svg": self = .html
        case "css", "scss", "sass", "less": self = .css
        case "md", "mdx", "markdown": self = .markdown
        case "rs": self = .rust
        case "go": self = .go
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm": self = .cFamily
        case "yml", "yaml": self = .yaml
        case "toml": self = .toml
        case "sql": self = .sql
        case "rb", "rake": self = .ruby
        case "java": self = .java
        case "kt", "kts": self = .kotlin
        case "php": self = .php
        case "ini", "cfg", "conf", "properties": self = .configuration
        default: self = .plainText
        }
    }
}
