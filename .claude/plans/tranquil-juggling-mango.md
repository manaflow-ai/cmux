# Fix Terminology: Tabs vs Workspaces

## Context

The settings UI has inconsistent terminology. Cmd-N is labeled "New Tab" but actually creates a sidebar workspace. "Next/Previous Surface" shortcuts navigate horizontal tabs but use the non-user-facing term "Surface". This creates confusion: there's "New Tab" but no "Next Tab", and "Next Workspace" but no "New Workspace".

**User's terminology rule:**
- **Horizontal tab bar items** = "Tabs" (Cmd-T creates one)
- **Vertical sidebar items** = "Workspaces" (Cmd-N creates one)

## Changes

### 1. `Sources/KeyboardShortcutSettings.swift` — Labels only (not enum cases or defaultsKeys)

| Enum case | Old label | New label |
|-----------|-----------|-----------|
| `.newTab` | "New Tab" | **"New Workspace"** |
| `.newSurface` | "New Surface" | **"New Tab"** |
| `.nextSurface` | "Next Surface" | **"Next Tab"** |
| `.prevSurface` | "Previous Surface" | **"Previous Tab"** |

Enum case names and `defaultsKey` values stay unchanged to preserve user settings in UserDefaults.

### 2. `Sources/cmuxApp.swift` — Menu items

| Line | Old text | New text |
|------|----------|----------|
| 406 | `Button("Next Surface")` | `Button("Next Tab")` |
| 410 | `Button("Previous Surface")` | `Button("Previous Tab")` |
| 470 | `Button("Tab \(number)")` | `Button("Workspace \(number)")` |

### 3. `Sources/ContentView.swift` — Rename dialog (renames sidebar workspace items)

| Line | Old text | New text |
|------|----------|----------|
| 1997 | `"Rename Tab"` | `"Rename Workspace"` |
| 1998 | `"Enter a custom name for this tab."` | `"Enter a custom name for this workspace."` |
| 2000 | `"Tab name"` | `"Workspace name"` |

### 4. `Sources/cmuxApp.swift` — Debug menu (consistency)

| Line | Old text | New text |
|------|----------|----------|
| 276 | `"New Tab With Lorem Search Text"` | `"New Workspace With Lorem Search Text"` |
| 280 | `"New Tab With Large Scrollback"` | `"New Workspace With Large Scrollback"` |

### 5. Revert node_modules change

`git checkout -- node_modules/.bin/esbuild` to ensure no node_modules changes in the PR.

## What stays the same

- Enum case names (`.newTab`, `.newSurface`, `.nextSurface`, `.prevSurface`) — internal code
- `defaultsKey` values (`shortcut.newTab`, `shortcut.newSurface`, etc.) — persisted user settings
- Type alias `typealias Tab = Workspace` in TabManager — internal code
- Internal method names (`addTab()`, `selectNextTab()`, etc.) — internal code
- API/socket error messages referencing "Surface" — internal/developer-facing
- Close menu items already correct: "Close Tab" (Cmd-W) and "Close Workspace" (Cmd-Shift-W)

## Verification

Build to verify no compile errors:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
```
