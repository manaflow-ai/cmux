# File Explorer

Sidebar file browser with native text editor, added as a fork feature on `feat/file-explorer`.

## Architecture

- `FileExplorerNode.swift` — Recursive data model for file/directory tree nodes. Handles lazy directory scanning, gitignore-aware filtering, and SF Symbol icon mapping by file extension.
- `FileExplorerState.swift` — ObservableObject managing tree state, visibility, divider position, search query, current editing file path, scroll-to target, and reveal toast message. Persists visibility/divider to UserDefaults. Watches filesystem via `DispatchSource`.
- `FileExplorerView.swift` — SwiftUI tree view with header (sync, refresh, search, menu), recursive rows with hover/highlight, context menus, draggable divider, and `ScrollViewReader` for reveal-file scrolling.
- `FileExplorerSidebarSection.swift` — Integration glue: connects explorer to workspace cwd via 1-second polling timer, syncs `currentEditingFilePath` from focused `EditorPanel`, routes file clicks to EditorPanel or Sublime Text.
- `SyntaxHighlighter.swift` — Pure Swift regex-based syntax coloring (VS Code color palette). Supports C-family, Python, HTML/XML. Returns `NSAttributedString`.
- `BracketMatcher.swift` — Pure utility for highlighting matching bracket pairs (`()`, `{}`, `[]`) at cursor position.
- `GitStatusProvider.swift` — Runs `git status --porcelain` to build a `[nodeId: GitFileStatus]` map. Handles both direct repos and parent directories containing multiple repos.

## Key patterns

- CWD sync uses `Timer.publish(every: 1.0)` polling `workspace.currentDirectory` — Combine publisher approach failed due to SwiftUI re-evaluation issues.
- Search uses `displayNodes` computed property that recursively filters `rootNodes`. On first search, `ensureAllChildrenLoaded(maxDepth: 6)` eagerly loads directory contents.
- File highlight: `currentEditingFilePath` is synced from the focused `EditorPanel` on each poll tick (not just on explorer clicks). Checked in `FileExplorerRow.rowBackground`.
- Reveal file: `revealFile()` expands parent directories, sets `scrollToNodeId`, and `ScrollViewReader` scrolls to it. Uses `VStack` (not `LazyVStack`) so all expanded nodes are available for scroll targeting.
- Git status: refreshed on every poll tick via `refreshGitStatusOnly()`. Colors propagate from parent directories to children (e.g., untracked dir → all children gray).
- Debug logging: all `debugLog()` calls are gated behind `#if DEBUG`. Writes to `/tmp/cmux-explorer-debug.log`.

## Editor panels

Editor files live in `Sources/Panels/`:
- `EditorPanel.swift` — Panel model: reads file, tracks dirty state, saves on Cmd+S.
- `EditorPanelView.swift` — SwiftUI view + `NativeTextEditor` (NSViewRepresentable wrapping NSScrollView + NSTextView). Coordinator handles text changes and debounced syntax re-highlighting.
- `SaveableTextView.swift` — NSTextView subclass with Cmd+S (via local event monitor), tab-to-2-spaces, and auto-indent on Enter.

## Gotchas

- `applyTheme` must NOT set `textView.textColor` — it overwrites syntax highlighting colors. Only set `backgroundColor` and `insertionPointColor`.
- NSRulerView (line numbers) breaks NSTextView text rendering in this setup — was removed after multiple failed attempts.
- `isRichText` must stay `false` — the syntax highlighter uses `textStorage?.setAttributedString()` which works with plain text mode.
- Cmd+S is intercepted by CMUX's menu system before reaching NSTextView. The `SaveableTextView` uses `NSEvent.addLocalMonitorForEvents` as a workaround.
