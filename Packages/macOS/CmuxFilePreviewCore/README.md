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

## Read-only Vim navigation

`ReadOnlyVimNavigation(text:)` owns navigation state for an immutable text snapshot.
`handle(_:)` updates UTF-16 cursor/selection coordinates and emits viewport or yank
results; it exposes no operation that writes the source. The AppKit preview owns
the interpreter and resets it when the document changes. Focus loss cancels pending
counts, prefixes, and search input. Tests instantiate it directly with fixture text.

The opt-in `app.filePreviewVimKeys` setting applies only to text file previews;
Markdown source editing and non-text previews retain their existing behavior.
Movement includes counts, h/j/k/l, w/b/e and W/B/E, 0/^/$, gg/G, f/F/t/T,
paragraphs, Ctrl-D/U/F/B, H/M/L and zz/zt/zb. Search uses / or ?, Enter,
and n/N. Marks use m followed by a character and apostrophe/backtick jumps;
Ctrl-O/I traverse the per-preview jump list. v/V select characters/lines and y
copies; Escape cancels selection or an unfinished command. Editing commands are
ignored and the native text view is non-editable. Existing Command shortcuts
retain precedence. Search patterns currently use Foundation regular expressions;
this is a read-only navigation interpreter, not an embedded Vim runtime.
