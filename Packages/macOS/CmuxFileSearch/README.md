# CmuxFileSearch

Project-wide search for the right sidebar's Find mode, independent of AppKit.

- `FileSearchQuery` holds the VS Code style options (Match Case, Match Whole
  Word, Use Regular Expression, include and exclude globs, Use Exclude Settings
  and Ignore Files). `RipgrepArguments` maps it to one `rg --json` argument
  vector that runs unchanged locally, over SSH and on a Cloud VM.
- `RipgrepJSONLineParser` and `RipgrepStreamDecoder` turn ripgrep output into
  one `FileSearchMatch` per submatch, with UTF-16 columns and a bounded preview
  around the match. Invalid UTF-8 (`"bytes"` payloads) is decoded consistently.
- `FileSearchProcess` spawns the command with `posix_spawn` in its own process
  group, so arguments are not Unicode-normalized and cancellation also stops
  processes the command started.
- `FileSearchEngine` debounces requests with an injected `Clock`, cancels
  superseded searches, and applies streamed batches to `FileSearchResultTree`
  at most once per frame. `FileSearchRowList` flattens the tree into table
  rows: `NSOutlineView` expansion is linear in the rows below each expanded
  item, which measured several seconds for 100,000 streamed matches, while
  appending table rows costs microseconds.

```bash
swift test --package-path Packages/macOS/CmuxFileSearch
```

`FileSearchPerformanceTests` prints decode and tree timings for 100,000
matches. The ripgrep end-to-end suite runs only when `rg` is installed.
