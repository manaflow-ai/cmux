# Tab Group Feature Plan

Chrome-style tab grouping for cmux's horizontal tab bar.

## Status
- [x] Repo cloned to `/Users/will/Repos/personal/cmux-color-tabs`
- [x] bonsplit submodule initialized at `vendor/bonsplit`, remote updated to `willfanguy/bonsplit`
- [x] Zig 0.15.2 installed, GhosttyKit.xcframework built and cached
- [x] Phases 2, 3, 4 — bonsplit data model, rendering, public API
- [x] **LINKER FIX** — All macOS static libs merged with collision-safe extraction
- [x] Phase 5 — cmux integration (context menu, persistence, workspace tie-in)
- [x] Phase 5 extras — group rename/delete/color via pill context menu, solid color fill on grouped tabs
- [x] Phase 6a: Collapse groups
- [x] Phase 6b: Drag tabs onto group pills
- [x] Phase 7: Localized strings (en + ja in bonsplit Localizable.strings)
- [ ] Phase 8: Keyboard shortcuts (deferred — Will doesn't use custom shortcuts)

## Architecture Summary

### Rendering chain
```
cmux TabManager (workspaces)
  └── WorkspaceContentView
        └── BonsplitView (workspace.bonsplitController)
              └── PaneContainerView (one per split pane)
                    └── TabBarView  ← group headers render here
                          └── TabItemView (one per tab)
```

### Key files

**bonsplit** (`vendor/bonsplit/Sources/Bonsplit/`):
- `Internal/Models/TabItem.swift` — internal tab model; add `groupId: UUID?`
- `Internal/Models/PaneState.swift` — pane state; add `var groups: [TabGroup]`
- `Internal/Views/TabBarView.swift` — ForEach at line 119; change to grouped rendering
- `Internal/Views/TabGroupHeaderView.swift` — NEW: colored pill label view
- `Internal/Styling/TabBarColors.swift` — may need group color helpers
- `Public/Types/Tab.swift` — public snapshot; add `groupId: UUID?`
- `Public/Types/TabGroup.swift` — NEW: public `TabGroup` struct
- `Public/Types/TabContextAction.swift` — add `addToGroup`, `removeFromGroup`, `newGroup`
- `Public/BonsplitController.swift` — add `createGroup/assignTab/removeTabFromGroup/deleteGroup`

**cmux** (`Sources/`):
- `WorkspaceContentView.swift` — handle new context actions
- `SessionPersistence.swift` — serialize/restore groups
- `Resources/Localizable.xcstrings` — localize new menu strings

## Phases

### Phase 2 — bonsplit data model (NEXT)
Purely additive. No visible UI change yet.

1. Create `Public/Types/TabGroup.swift`:
   ```swift
   public struct TabGroup: Identifiable, Codable, Hashable, Sendable {
       public let id: UUID
       public var name: String
       public var colorHex: String  // e.g. "8B5CF6"
   }
   ```

2. Add to `Internal/Models/TabItem.swift`:
   - `var groupId: UUID?` field
   - Add to `CodingKeys`, `init`, `encode`, `decode` (use `decodeIfPresent`, default nil)

3. Add to `Internal/Models/PaneState.swift`:
   - `var groups: [TabGroup] = []`
   - `func addGroup(_ group: TabGroup)`
   - `func removeGroup(_ groupId: UUID)` — also clears groupId from all member tabs
   - `func group(for id: UUID) -> TabGroup?`

**Checkpoint:** `./scripts/reload.sh --tag color-tabs` — green build (once baseline build is fixed)

### Phase 3 — bonsplit rendering
Change `TabBarView`'s `ForEach` from flat tab list to grouped elements.

Approach — local enum inside TabBarView:
```swift
private enum TabRowElement: Identifiable {
    case groupHeader(TabGroup)
    case tab(index: Int, item: TabItem)
    var id: String { ... }
}
```

Computed var `tabRowElements` sorts tabs by group, inserting a `.groupHeader` before each group's first tab.

New `TabGroupHeaderView`: colored pill (RoundedRectangle fill) with group name text, same height as tabs (30pt). Tapping a group header could eventually collapse it (Phase 6).

**Checkpoint:** Build + `--launch`. Create a test group in debug to verify headers render.

### Phase 4 — bonsplit public API
- Add `addToGroup`, `removeFromGroup`, `newGroup` to `TabContextAction`
- Add `createGroup/assignTab/removeTabFromGroup/deleteGroup` to `BonsplitController`
- Add `groupId: UUID?` to public `Tab` struct
- Expose `TabGroup` publicly

**Checkpoint:** Green build. No cmux changes yet.

### Phase 5 — cmux integration
- Handle new context actions in `WorkspaceContentView`
- Persist groups in `SessionPersistence`
- Add localized strings

**Checkpoint:** End-to-end: create group → assign tabs → quit → relaunch → groups survive.

### Phase 6a — Collapse groups (NEXT)
Click the group pill to collapse/expand. Collapsed groups show only the pill + a count badge; tabs are hidden from the tab bar but remain in the pane.

**bonsplit changes:**
1. `TabGroup` — add `var isCollapsed: Bool = false`
2. `TabItem` coding — `isCollapsed` does NOT go on TabItem; it's a group-level property
3. `PaneState` — add `func toggleGroupCollapsed(_ groupId: UUID)`
4. `TabBarView.tabRowElements` — when group is collapsed, emit `.groupHeader` but skip `.tab` elements for that group
5. `TabGroupHeaderView` — add click handler for collapse toggle, show tab count badge when collapsed (e.g. "Group 1 (3)"), rotate the dot or add a chevron indicator
6. `BonsplitController` — add `toggleGroupCollapsed(_:inPane:)` and `isGroupCollapsed(_:inPane:) -> Bool`

**cmux changes:**
7. `SessionPersistence` — add `isCollapsed` to `SessionTabGroupSnapshot`

**Checkpoint:** Create group → add 3 tabs → click pill → tabs collapse to count badge → click again → tabs expand

### Phase 6b — Drag tabs between groups
Allow dragging a tab onto a group pill to assign it to that group, and dragging out to ungroup.

**bonsplit changes:**
1. `TabGroupHeaderView` — add `.onDrop(of: [.tabTransfer])` that calls `controller.assignTab(draggedTabId, toGroup: group.id)`
2. `TabBarView` — when a tab is dragged past the last group member, ungroup it (set `groupId = nil`)
3. Consider visual feedback: highlight the group pill when a tab hovers over it

**Checkpoint:** Drag tab onto group pill → tab joins group → drag tab out past group boundary → tab leaves group

### Phase 7 — Localized strings
Add all group-related strings to `Resources/Localizable.xcstrings`. Strings needed:
- "New Group", "Add to Group", "Remove from Group" (tab context menu)
- "Rename Group…", "Group Color", "Delete Group" (pill context menu)
- Color names: "Indigo", "Red", "Green", "Amber", "Purple", "Pink", "Cyan", "Slate"
- "Rename Group" / "Enter a new name for the group." (alert dialog)
- Group count badge format (e.g. "(3)")

### Phase 8 — Keyboard shortcuts
Following cmux's shortcut policy (KeyboardShortcutSettings, settings.json, docs):
- Cycle to next/previous group within a pane
- Move focused tab to next/previous group
- Toggle collapse on focused group
- Create new group from focused tab

## Linker fix strategy

Root cause: Zig 0.15.2 + Xcode 26.4's `libtool -static` extracts .o files with `----------` permissions, so when it tries to re-archive them into libghostty-fat.a, some objects end up corrupted/empty. The archive has 144 entries, but several are zero-content.

### What Zig builds
- `libghostty-fat.a` (per-arch, from LibtoolStep) = ghostty + most deps merged via libtool
- `libghostty.a` (universal fat) = lipo of the two libghostty-fat.a files

### What's missing from libghostty-fat.a
The fat archives in `.zig-cache` are MISSING these symbols despite containing the .o entries:
1. **FreeType** (`_FT_Activate_Size`, `_FT_Done_Face`, ~60 symbols) — dcimgui and imgui_freetype reference them
2. **2 ImGui symbols** (`_ImFontConfig_ImFontConfig`, `_ImGuiStyle_ImGuiStyle`) — in libdcimgui.a but corrupted in fat archive
3. **glslang C API** (`_glslang_initialize_process`, etc.) — in libglslang.a but not in fat

### Source archives in .zig-cache (verified macOS builds)
- **FreeType arm64** macOS: `.zig-cache/o/b30deca0.../libfreetype.a`
- **FreeType x86_64**: `.zig-cache/o/6b8c55d5.../libfreetype.a`
- **dcImGui arm64** macOS (platform 1): `.zig-cache/o/59263348.../libdcimgui.a`
- **dcImGui x86_64**: `.zig-cache/o/4d3baa9f.../libdcimgui.a`
- **glslang arm64** macOS: `.zig-cache/o/bd0dd80.../libglslang.a` (or bee68dd or fac3431 — all 3 have the symbol; pick newest)
- **glslang x86_64**: `.zig-cache/o/91cc2c59.../libglslang.a`
- **libghostty-fat arm64** (macOS, confirmed): `.zig-cache/o/0827238b.../libghostty-fat.a` (63M)
- **libghostty-fat x86_64**: `.zig-cache/o/01118def.../libghostty-fat.a` (92M)

### Fix applied (2026-04-06)

**Key learnings:**
1. The original plan only identified 3 missing libs, but there were actually **13** supplemental libs missing
2. `ar x` into a flat directory loses objects to filename collisions — must extract into separate subdirs and prefix .o names
3. Multiple platform variants exist in the cache (platform 1=macOS, 2=iOS, 7=macCatalyst) — must verify platform via `otool -l` on extracted objects
4. `libghostty.a` (not `-fat`) contains `ghostty_simd_*` and compiler-rt builtins (`__extenddftf2`) that are NOT in `libghostty-fat.a`

**Verified macOS (platform 1) archive hashes:**

| Library | arm64 hash | x86_64 hash |
|---------|-----------|-------------|
| libghostty-fat | 0827238bc6bc3fc8b671577960d1cc60 | 01118def0a6e0911bdc7bdc37e460931 |
| libghostty | 421ac9a40e5d2125fa6d01147f107f80 | bc182e2d4f285987479560ea48af49b8 |
| libfreetype | b30deca0d4fc56e4b4b920848d27308a | 6b8c55d5abb2d51b74014ac5f9ab2155 |
| libdcimgui | 59263348bf092d9ee0a1ed2577030255 | 4d3baa9f34b814e12ea30d8ad8b54556 |
| libglslang | bee68ddebe77aa68b789295d420f31d3 | 91cc2c59526e644449420be41972b50c |
| libbreakpad | 7326087ccd55e6f87d75def414c13093 | 140776d973b01d3bda5eba8acb6a22e6 |
| libhighway | d3b7fbef0d5e3b4303d33820e7648563 | a270fb4f7a4515f4cea13154228f3f63 |
| libintl | cffd638a358b5934d8651376871083ff | 5c560adca6f5695caa1c5d0d8bd79c57 |
| libmacos | 1c4e205d81e591f44863da7ec5af31b7 | 29317b4afc51ce58a31edfc82fedc630 |
| liboniguruma | 2a2a50c881a17bfb50cd772e057aace8 | 7e61defe5158fde804c55b8e95c6dd06 |
| libpng | f8d00ab4917838cbc160422f943af34a | 9cd75acc40df831c6c1fb7244184a47d |
| libsentry | 417cd3f196deeeab57b7c8e8a678b5c2 | 04e77b0413c1a1d277d2421d966d7679 |
| libsimdutf | d7e3044e187155215c059730efbbbe10 | 3db12561d45267ffbc69e466f1dccb41 |
| libspirv_cross | d7da8c9077cc92c66888c1590b2b65de | 126f72b9f8877ec288ae9f401c204616 |
| libutfcpp | 89b9d464aca4bca902c5eebc37ca52c8 | cd0934d5a960c758d0255bdbd2cf7b17 |
| libz | a12afe9e3c23c5dd4630da27ee71935e | 0055190734f2cabf26f2217ab656a3a2 |

**Result:** 427M universal archive, BUILD SUCCEEDED.

## Build notes
- Always: `./scripts/reload.sh --tag color-tabs`
- Never: bare `xcodebuild` or untagged builds
- bonsplit is a submodule — push changes to `willfanguy/bonsplit` before committing the submodule pointer in cmux
- All user-facing strings → `Localizable.xcstrings`
