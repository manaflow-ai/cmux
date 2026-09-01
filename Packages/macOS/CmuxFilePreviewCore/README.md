# CmuxFilePreviewCore

`CmuxFilePreviewCore` contains platform-independent data structures shared by
the macOS File Preview views. `FilePreviewLineIndex` stores UTF-16 line starts
and applies text-storage edits with lazy suffix offsets, so the AppKit gutter
does not rescan a large document for every keystroke.

The index recognizes LF, CR/CRLF, and Unicode line separators when it is built.
The AppKit gutter rebuilds from its authoritative `NSTextStorage` for documents
using the extended separators, because a single UTF-16 edit can split or join a
CRLF pair without exposing the deleted code unit in an edit notification. LF-only
documents retain the logarithmic lazy-edit path.

The package has no filesystem or `UserDefaults` dependency and can be tested
directly with SwiftPM:

```bash
swift test --package-path Packages/macOS/CmuxFilePreviewCore
```
