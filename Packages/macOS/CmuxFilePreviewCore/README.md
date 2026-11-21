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

`FilePreviewGitLineDiff` compares the live buffer with its git base and returns
a `FilePreviewGitLineChange` (added, modified, removed, or removedAtEnd) keyed by
1-based line number for the gutter's change stripe. It splits lines on the same
breaks as `FilePreviewLineIndex`, so markers land on the lines the gutter
numbers, and it skips inputs over 20,000 lines or 2 MiB.
`FilePreviewGitGutterMarkers` pairs those changes with whether the file is
tracked at all, so the gutter can reserve its stripe column for a tracked file
before the first edit and never shift the text.

```swift
let changes = FilePreviewGitLineDiff().changes(base: "one\ntwo\n", current: "one\nTWO\n")
// [2: .modified]
```

The package has no filesystem or `UserDefaults` dependency and can be tested
directly with SwiftPM:

```bash
swift test --package-path Packages/macOS/CmuxFilePreviewCore
```
