# CmuxFilePreviewSyntax

Native, dependency-free syntax highlighting for editable file previews. The package owns
filename-to-language resolution, bounded tokenization, and light/dark palette values. AppKit
integration stays in the cmux app target so the package can be tested without launching cmux.

The scanner is deliberately best-effort rather than a compiler frontend. It recognizes common
keywords, types, strings, numbers, comments, calls, and annotations while preserving UTF-16 ranges
for TextKit. Callers gate work with `FilePreviewSyntaxHighlightPolicy`; oversized or token-dense
files degrade to plain text.

## Usage

```swift
import CmuxFilePreviewSyntax

let resolver = FilePreviewSyntaxLanguageResolver()
let highlighter = FilePreviewSyntaxHighlighter()

if let language = resolver.language(forFilename: "query.sql") {
    let result = highlighter.highlight(
        "SELECT * FROM users",
        language: language,
        maximumTokenCount: 12_000
    )
    // Apply result.tokens as temporary TextKit attributes.
}
```

UI callers use `highlightOffMain` and own cancellation at their lifecycle boundary. Tests use the
synchronous value-in/value-out API directly.
