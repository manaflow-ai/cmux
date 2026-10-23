# CmuxTextMatching

Pure text matchers for search pickers, with no app or AppKit dependencies.

- `FzfAlgorithm` ports fzf's matching algorithms (V2 Smith-Waterman-style fuzzy
  scoring, V1, exact, prefix, suffix and equal), with fzf's bonuses for word
  starts, delimiters, camelCase and consecutive runs and its gap penalties.
- `FzfQuery` parses fzf's extended-search syntax (`'exact`, `^prefix`,
  `suffix$`, `!not`, `a | b`) with smart case and scores with V2.
- `TmuxGlobPattern` matches globs the way tmux `find-window` does, through the
  semantics of `fnmatch(3)`.
- `PaneContentMatcher` searches lines of pane text as literal text, a tmux glob
  or a regular expression, with smart, ignored or respected case.

Everything is a value type; tests construct them directly:

```swift
let query = FzfQuery("main win")
let match = query.match("main-window")   // score and highlight positions

let glob = TmuxGlobPattern("disk*full", caseInsensitive: false)
let range = glob.firstMatch(in: "error: disk full on /dev/sda1")

let matcher = try PaneContentMatcher(query: "error", syntax: .text, caseMode: .smart)
let hit = matcher.firstMatch(in: "FATAL ERROR")
```

Run the tests with `swift test` from this directory.
