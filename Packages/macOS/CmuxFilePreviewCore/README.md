# CmuxFilePreviewCore

`CmuxFilePreviewCore` contains platform-independent data structures shared by
the macOS File Preview views. `FilePreviewLineIndex` stores UTF-16 line starts
and applies text-storage edits with lazy suffix offsets, so the AppKit gutter
does not rescan a large document for every keystroke.

The package has no filesystem or `UserDefaults` dependency and can be tested
directly with SwiftPM:

```bash
swift test --package-path Packages/macOS/CmuxFilePreviewCore
```
