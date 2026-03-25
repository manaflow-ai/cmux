# GitDiffPanel Architecture Spec

**Author:** Woz  
**Date:** 2026-03-17  
**Status:** Draft for review  
**Repo:** `ronnie3786/cmux` (fork of `manaflow-ai/cmux`)

---

## Overview

A new `GitDiffPanel` panel type for cmux that shows changed files + inline diffs. Think Tower-lite, embedded in a split. Follows the existing Panel protocol exactly.

## Design principles

- Follow the MarkdownPanel pattern (simpler, read-only, file-watching) rather than BrowserPanel (which is a 2000+ line monster with navigation history, downloads, DevTools, etc.)
- Use WebKit only for the diff rendering pane (right side), not for the file list
- Keep the panel self-contained. No new frameworks beyond what's already linked.

---

## Files to create

### 1. `Sources/Panels/GitDiffPanel.swift` (~350-400 lines)

The model. Conforms to `Panel` protocol.

```swift
@MainActor
final class GitDiffPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .gitDiff  // new case

    // Workspace binding
    private(set) var workspaceId: UUID

    // Git state
    @Published private(set) var changedFiles: [GitChangedFile] = []
    @Published private(set) var selectedFile: GitChangedFile? = nil
    @Published private(set) var diffHTML: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var displayTitle: String = "Git Changes"
    @Published private(set) var focusFlashToken: Int = 0

    var displayIcon: String? { "arrow.triangle.branch" }

    // File watching
    private var gitIndexWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(
        label: "com.cmux.git-diff-watch", qos: .utility
    )

    // Working directory (resolved from workspace)
    let workingDirectory: String
}
```

**Key data types:**

```swift
struct GitChangedFile: Identifiable, Hashable {
    let id: String           // relative path (unique within a repo)
    let path: String         // relative path
    let status: GitFileStatus
    let staged: Bool
}

enum GitFileStatus: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
}
```

**Core methods:**

- `init(workspaceId:, workingDirectory:)` -- resolves `.git/index` path, starts watcher
- `refreshGitStatus()` -- runs `git status --porcelain` on `watchQueue`, parses output, updates `changedFiles` on main actor
- `selectFile(_ file:)` -- runs `git diff -- <path>` (or `git diff --cached` for staged), pipes output through diff2html template, updates `diffHTML`
- `startGitIndexWatcher()` -- DispatchSource on `.git/index` for `.write`, `.delete`, `.rename`, `.extend` (same pattern as MarkdownPanel's file watcher)
- `close()` -- stops watcher, cleans up
- `focus()` / `unfocus()` / `triggerFlash()` -- standard Panel protocol

**File watcher target:** Watch `.git/index` (covers staging changes) AND `.git/refs/heads/` directory (covers commits/branch switches). Use two DispatchSources, or watch the `.git` directory with a broader mask. Debounce refreshes by 200ms to avoid hammering during rapid operations like `git add .`.

**Git command execution:** Use the same pattern as `TabManager.runGitCommand()` (line 1194 of TabManager.swift):

```swift
private nonisolated static func runGitCommand(
    directory: String, arguments: [String]
) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory] + arguments
    // ... pipe, launch, wait, read stdout
}
```

Run on `watchQueue`, dispatch results back to main actor.

### 2. `Sources/Panels/GitDiffPanelView.swift` (~200-250 lines)

The SwiftUI view. Two-column layout.

```
┌─────────────────────────────────────────────────┐
│ Git Changes (3 files)                    branch  │
├──────────────┬──────────────────────────────────┤
│ M  file1.swift│                                  │
│ A  file2.swift│   diff2html rendered diff        │
│ D  file3.swift│   (WKWebView)                    │
│              │                                  │
│              │                                  │
├──────────────┴──────────────────────────────────┤
│ [Staged] [Unstaged] [All]              Refresh ↻│
└─────────────────────────────────────────────────┘
```

**Left column:** Native SwiftUI `List` with selection binding. Each row shows status icon (color-coded: green for added, orange for modified, red for deleted) + relative file path. Group by staged/unstaged with section headers.

**Right column:** `WKWebView` wrapped in `NSViewRepresentable`. Loads diff HTML via `loadHTMLString`. Reuses the same `WKWebView` instance across file selections (just reload the HTML string). No need for BrowserPanel's full navigation stack, history, process pool, etc. This is a disposable local renderer.

**Diff HTML template:**

```swift
private static func diffHTMLTemplate(diffOutput: String, isDark: Bool) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
      <style>\(diff2htmlCSS)</style>
      <style>
        body {
          margin: 0; padding: 8px;
          background: \(isDark ? "#1e1e1e" : "#ffffff");
          color: \(isDark ? "#d4d4d4" : "#1e1e1e");
          font-family: -apple-system, SF Mono, Menlo, monospace;
          font-size: 12px;
        }
      </style>
    </head>
    <body>
      <div id="diff"></div>
      <script>\(diff2htmlJS)</script>
      <script>
        const diffString = \(diffOutput.jsonEscaped);
        document.getElementById('diff').innerHTML =
          Diff2Html.html(diffString, {
            drawFileList: false,
            outputFormat: 'line-by-line',
            matching: 'lines'
          });
      </script>
    </body>
    </html>
    """
}
```

Bundle `diff2html.min.js` (~40KB) and `diff2html.min.css` (~15KB) in `Resources/`. Load them as string constants at compile time (same approach cmux uses for other bundled JS).

**Empty states:**
- No git repo detected: "Not a git repository" with icon
- Clean working tree: "No changes" with checkmark icon
- No file selected: "Select a file to view diff" hint

### 3. Modifications to existing files

#### `Sources/Panels/Panel.swift`

Add one case to the enum:

```swift
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
    case gitDiff    // <-- new
}
```

#### `Sources/Panels/PanelContentView.swift`

Add the routing case:

```swift
case .gitDiff:
    if let gitDiffPanel = panel as? GitDiffPanel {
        GitDiffPanelView(
            panel: gitDiffPanel,
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            portalPriority: portalPriority,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }
```

#### `Sources/Workspace.swift`

Add these methods (follow the MarkdownPanel creation pattern exactly):

- `newGitDiffSplit(from:orientation:focus:)` -- creates GitDiffPanel in a new split
- `newGitDiffSurface(inPane:focus:)` -- creates GitDiffPanel as a new tab in existing pane
- `installGitDiffPanelSubscription(_:)` -- subscribes to title changes
- `gitDiffPanel(for:) -> GitDiffPanel?` -- accessor
- Add `SurfaceKind.gitDiff = "gitDiff"` constant

The working directory should be resolved from:
1. `currentDirectory` on the workspace (already tracked)
2. Or the focused terminal panel's `panelDirectories[panelId]`

Also add session snapshot/restore support:
- `SessionGitDiffPanelSnapshot` with `workingDirectory: String`
- Wire into `sessionPanelSnapshot()` and `createPanel(from:inPane:)`

#### `Sources/TabManager.swift`

Add keyboard shortcut and menu integration:

- `createGitDiffSplit(direction:)` -- mirrors `createBrowserSplit(direction:)`
- Wire to a keyboard shortcut. Suggest `Cmd+Shift+G` (check for conflicts first)
- Add to the command palette if one exists

#### `CLI/cmux.swift` (optional, Phase 2)

Add `git-changes` subcommand that sends a socket message to open the panel. Low priority, the keyboard shortcut is the primary entry point.

#### `Resources/`

Add two files:
- `Resources/diff2html.min.js`
- `Resources/diff2html.min.css`

Download from: https://cdn.jsdelivr.net/npm/diff2html/bundles/

---

## Data flow

```
.git/index write event
  → DispatchSource (watchQueue)
  → debounce 200ms
  → git status --porcelain (watchQueue)
  → parse → [GitChangedFile] (main actor)
  → SwiftUI List updates automatically

User selects file in list
  → git diff -- <path> (watchQueue)
  → wrap in diff2html HTML template
  → webView.loadHTMLString() (main actor)
```

## What I'm NOT building

- **Staging/unstaging from the panel.** This is a viewer, not a staging tool. Keep it read-only for v1. If Ronnie wants interactive staging later, that's a separate spec.
- **Commit UI.** Same reason. Terminal is right there.
- **Branch switching.** Out of scope.
- **Three-way merge view.** Not needed for the "Tower-lite" goal.
- **Custom diff engine.** `git diff` output + diff2html handles everything.

## Risk / open questions

1. **diff2html bundle size.** ~40KB JS + ~15KB CSS. Acceptable for an app that already ships WebKit. Confirm Ronnie is OK bundling this vs CDN (CDN would break offline use).

2. **File watcher sensitivity.** Watching `.git/index` catches most staging changes but might miss some edge cases (stash, rebase). Watching the whole `.git/` directory recursively would be more complete but noisier. I'd start with `.git/index` + debounce and iterate if needed.

3. **Large diffs.** diff2html can choke on very large diffs (10K+ lines). We should cap the raw diff output at ~500KB and show a "diff too large" message if exceeded. `git diff` supports `--stat` as a fallback view.

4. **Keyboard shortcut collision.** Need to verify `Cmd+Shift+G` isn't taken. If it is, `Cmd+Option+G` or `Cmd+Shift+D` (for diff) are alternatives.

---

## Estimated scope

| File | Lines | Complexity |
|------|-------|-----------|
| GitDiffPanel.swift | ~350-400 | Medium (file watching + git commands) |
| GitDiffPanelView.swift | ~200-250 | Medium (split layout + WebView) |
| Panel.swift | +1 line | Trivial |
| PanelContentView.swift | +8 lines | Trivial |
| Workspace.swift | ~120-150 new lines | Low (copy MarkdownPanel pattern) |
| TabManager.swift | ~30-40 new lines | Low (copy browser shortcut pattern) |
| Resources (diff2html) | 2 bundled files | Trivial |

Total new code: ~750-900 lines. Most of it follows existing patterns directly.

---

## Recommendation

Build Phase 1 (the panel) first. Get it rendering diffs in a split. Then wire up the keyboard shortcut and CLI command. The architecture is straightforward because cmux already has every building block we need. The MarkdownPanel pattern (DispatchSource file watching, read-only content, SwiftUI view) maps almost 1:1 to what we need here.

One thing I'd push back on from Ashley's original plan: don't use `NSOutlineView` for the file list. A SwiftUI `List` with `Section` headers for staged/unstaged is simpler, fits the existing codebase style (MarkdownPanelView is pure SwiftUI), and handles the expected file counts fine. We're not building Finder.
