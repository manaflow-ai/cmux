# CmuxFilePreviewCore

`CmuxFilePreviewCore` contains platform-independent data structures shared by
the macOS File Preview views. `FilePreviewLineIndex` stores UTF-16 line starts
and applies text-storage edits with lazy suffix offsets, so the AppKit gutter
does not rescan a large document for every keystroke.

The index recognizes LF, CR/CRLF, and Unicode line separators when it is built.
It retains separator kinds in packed line-break entries, so edits that split or
join a CRLF pair remain exact while the untouched suffix moves by a lazy delta.
No second document-sized source copy is retained; the AppKit gutter can apply
the same incremental edit path for every supported separator.

The package has no filesystem or `UserDefaults` dependency and can be tested
directly with SwiftPM:

```bash
swift test --package-path Packages/macOS/CmuxFilePreviewCore
```
