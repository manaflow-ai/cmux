# Proposed CmuxTabsKit changes for the tabs-kit owner

cmux-next-ios uses `Packages/iOS/CmuxTabsKit` exactly as `origin/feat-cmux-next-tabs-kit`
ships it (52bf6989026d when this was written). We do not patch the package. These
are proposals only; nothing was pushed to `feat-cmux-next-tabs-kit`.

## 1. Swipe fade expression does not type-check on Xcode 26.3

- **Where:** `UI/Toolbar.swift`, the label's swipe fade:
  `.opacity(chrome.swiping ? 1 - min(1, abs(chrome.swipeOffset) / (size.width * 0.5)) : 1)`.
- **Problem:** Xcode 26.3 (the CI and `mini-cmuxs-mac-mini-2` toolchain) failed to
  compile it; making the `CGFloat` to `Double` conversion explicit fixed it. Xcode 27.0
  compiles it, so local and demo builds on this laptop are fine.
- **Fix cmux-next-ios carried until this sync (28bcdc4d46e0):**

  ```swift
  .opacity(chrome.swiping ? Double(1 - min(CGFloat(1), abs(chrome.swipeOffset) / (size.width * 0.5))) : 1)
  ```

- **Why not host code:** it is inside the package's own toolbar; no data source
  API reaches it.

## 2. Accessory row sinks under the toolbar during an interactive keyboard dismissal

- **Where:** `UI/TabsView.swift`, the accessory row's
  `.padding(.bottom, keyboard > 0 ? keyboard : size.height - layout.capsule.minY + 8)`.
- **Problem:** while the user drags the keyboard down, the keyboard passes under
  the toolbar before it reports 0, and the row follows it down, then jumps back.
- **cmux-next-ios today:** handled in host code. `AccessoryFloor` in
  `CmuxMobileWorkspaces/WorkspaceTabsSource.swift` lifts the row by however far it would
  sink below `context.pageSize.height - context.safeAreaInsets.bottom` (toolbar
  expanded only). Traces match the earlier in-package `max(keyboard, resting)` fix
  frame for frame (`verify/tabskit-sync.md`).
- **Proposal:** take `max(keyboard, size.height - layout.capsule.minY + 8)` in the
  package so every client gets it; cmux-next-ios would then drop `AccessoryFloor`.
- **Still open in both versions:** for 3 to 4 frames at the end of the drag
  (keyboard top 843 to 862 pt on iPhone 17 Pro) the row sits 14 pt low. That comes
  from SwiftUI's keyboard safe-area inset; pinning the row to a UIKit keyboard
  layout guide in the package would remove it (`verify/keyboard.md`).
