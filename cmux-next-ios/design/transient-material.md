# Transient material on iOS

Leo, 2026-11-11: translucency is intended; use one coherent material style,
never an opaque replacement. This updates SPEC 2.4 and 4.8, including the old
full-height opaque-sheet rule. Chat visual landing remains held. This document
records the non-chat baseline; the separate
[chat-adoption draft](../../design/transient-material-chat.md) removes the scoped
exceptions and adds the actual context-popover gallery while remaining unmerged.

## Material and scope

`schemas/design-scale/design-scale.json` owns the shared material token; the generator checks its parity with
the hand-maintained `CmuxTheme.TransientMaterial.standard` declaration. `CmuxMobileTransientMaterial` uses its
neutral colors, veil alpha and native tint strength. It never reads a paired Mac's
palette. Floating surfaces use regular Liquid Glass; native sheets use regular
system material plus the same neutral veil. Glass retains the OS Reduce Transparency fallback without a tint; sheet presentation
uses an opaque system background with no veil under Reduce Transparency. No shape, placement, stacking, dismissal or motion changes.

The standard is the production candidate. The gallery compares the exact previous
material with 0.75×, 1× and 1.25× veil strengths; alternatives are DEBUG-only.
Fleet screenshots and review must establish the visual verdict before describing
the candidate as visually verified.

All paths below are relative to `CmuxMobileKit/Sources/`.

| Surface / owner | Material route | Chat boundary |
| --- | --- | --- |
| Shell toast, `CmuxMobileShell/RootView.swift` | `CmuxMobileToastContent` → transient glass | Opt-in on Settings, unpushed Home/Workspaces/Feed lists, and positively non-chat workspace metadata; Cloud Chats/Chief compose, pushed Home/Feed routes and ambiguous workspace states retain prior glass. |
| Local chat toast, `CmuxMobileAgentChat/ParityViews.swift` | Original regular glass through nil parameter | No caller edit; shared toast default remains nil. |
| Workspace opening/refusal toast, `CmuxMobileWorkspaces/WorkspaceScreen.swift` | Transient glass, same capsule/card | Grid or identified non-agent tab only; agent/unknown tab retains prior glass. |
| Pane toast, `CmuxMobileWorkspaces/PanesScreen.swift` | Transient glass | Separate pane-management page, not transcript. |
| Screens/group page toast, `CmuxMobileWorkspaces/WorkspaceTabsSource+GroupsScreens.swift` | Legacy glass; adoption in chat draft | Groups can contain agent tabs; mixed pushed route stays held. |
| Connection banner, `CmuxMobileShell/Screens.swift` | Explicit `.standard` on shared banner | Shared initializer/modifier default remains nil. ConversationsHome banner is adopted in the held chat draft. |
| Home Updating notice, `CmuxMobileChief/ConversationsHome.swift` | Legacy material; adoption in chat draft | Conversation destination remains held. |
| Ended-shell recovery card, `CmuxMobileWorkspaces/WorkspaceTabsSource.swift` | Transient glass | Terminal case only. |
| QR scanner hint, `CmuxMobileSettings/PairCodeScanner.swift` | Transient glass | Settings only. |
| Command palette, `CmuxMobileWorkspaces/CommandPaletteSheet.swift` | Shared native sheet modifier and hidden list backdrop | Receives the workspace's scoped material; unchanged over agent/unknown tabs. |
| Move/add/saved group pickers, `CmuxMobileWorkspaces/TabMoveAndGroupSheets.swift` | Shared native sheet modifier | Same workspace scope. |
| Group move picker, `CmuxMobileWorkspaces/TabGroupPage.swift` | Legacy sheet; adoption in chat draft | A group can contain agent tabs. |
| Agent chooser / screen-sharing sheet, `CmuxMobileWorkspaces/WorkspaceScreen.swift` | Shared native sheet modifier | Same workspace scope; no transcript change. |
| Workspace icon picker, `CmuxMobileWorkspaces/WorkspaceIconPicker.swift` | Shared native sheet modifier; removed both opaque child fills | Workspace list entry. |
| Team appearance, `CmuxMobileSettings/TeamAppearanceEditor.swift` | Shared native sheet modifier; removed production content/presentation opaque fills | Both Settings and sidebar entry points. Old fills exist only for gallery before mode. |
| Email/code sign-in, `CmuxMobileOnboarding/EmailSignIn.swift` | Shared native sheet modifier; removed opaque email and code-page backdrops | Signed-out flow. |
| Pair scanner / machine invite | Scanner modifier and root invite modifier; invite list backdrop hidden | Settings/universal-link presentation. |
| Connected devices, `CmuxMobileShell/RootView.swift` | Shared native sheet modifier | Terminal device sheet. |
| Terminal Files and Links, `CmuxMobileTerminal/Screen/{TerminalScreen,TerminalViewController}.swift` | Shared native sheet modifier at SwiftUI and UIKit entry points | Terminal only; chat artifact sheet untouched. |
| Browser select, `CmuxMobileBrowserStream/StreamedBrowserPage.swift` | Shared native sheet modifier | Streamed browser only. |
| New Cloud Machine, `CmuxMobileChief/CloudMachinesScreen.swift` | Shared native sheet modifier | Settings machine management. |

### System-owned and held surfaces

- `Menu`, UIKit `UIMenu`, context menus, confirmation dialogs, alerts, share
  controllers and Quick Look keep system presentation. They have no supported
  arbitrary app material-token background. Replacing them is outside this change.
  Workspace row menus remain lazily constructed (`WorkspacesListMenus.swift`).
- `CmuxMobileAgentChat/SessionMeterViews.swift` owns the only explicit SwiftUI
  `.popover` found in this audit (ContextUsageRing); it stays held. Chat/Chief
  sheets, composers, voice bars, find bars and local chat toasts stay unchanged.
- No custom iOS tooltip component or `.help` implementation was found. OS hints
  and external TabsKit chrome are not claimed as custom-token consumers.
- Billing audit: `Packages/iOS/CmuxMobileBilling` has no custom material or opaque
  backdrop. Production Settings pushes `MobilePlansView`, not a transient sheet.
  The only `MobilePlansSheet` call site in this app is `BillingDemoSheet`; it now
  applies the common sheet modifier at the call site, avoiding a dependency cycle.
  StoreKit purchase, manage-subscription and refund sheets remain system-owned.
- Root shell toasts now opt in on nonempty workspaces with no agent tabs, and on
  mixed workspaces when both the recorded active tab and freshly resolved opening
  tab are non-agent and no tab-open request is pending. `WorkspaceTabsSource`
  updates `AppStore.lastTabByWorkspace` on activation; requiring the opening tab
  too prevents stale persisted memory from styling a chat during initial entry.
  Home and Feed pushes are conversation destinations and remain held.
- Exact remaining conservative cases: root-originated team/invite/save toasts on
  a workspace grid or management page whose recorded tab is an agent; non-chat
  tabs in a mixed workspace whose opening/layout tab is an agent; a synthetic
  screen-sharing tab entered from an agent; missing/empty workspace metadata;
  and a pending tab-open request. The root has no source-owned overview/route
  state, and adding navigation tracking is outside this change. The
  workspace-owned opening/refusal toast is independently migrated on its grid
  and known non-agent tabs. These exceptions are not claimed as full coverage;
  no global environment switch reaches chat descendants.
- Generic `Materials.swift` controls, composer glass, CTA glass and inline
  FailureCard remain unchanged: persistent chrome/content is not a transient.

## Held root-toast adoption

The separate chat-adoption draft can replace the root call with
`.cmuxMobileToast($shell.toast, material: .standard)` and remove
`ShellView.nonChatToastMaterial`. This closes the conservative root-toast cases
without adding navigation tracking. It also changes root toasts over chat, so
that draft must remain unmerged until chat visual landing is permitted. It must
not flip the shared modifier's nil default: `ParityViews` and other held local
chat consumers are separate adoption surfaces.

## Capture commands and acceptance

Use the fleet iOS capture runner with the DEBUG build and these launch arguments:

```text
-cmux-mobile-recovery-gallery transient-toast|transient-banner|transient-sheet|transient-palette|transient-menu
-cmux-mobile-material-variant before|quieter|standard|denser
-cmux-mobile-gallery-appearance light|dark
```

`TransientMaterialCaptureUITests/testLightMaterials` and
`TransientMaterialCaptureUITests/testDarkMaterials` capture the complete 5 × 4 × 2
matrix (40 stills). It asserts the real sheet/palette/menu appeared before saving
`transient-<surface>-<variant>-<look>`. Sheet and palette galleries instantiate
production views; toast uses production content without its expiry timer;
banners use production ConnectionBanner. The menu is native and intentionally
identical across material candidates, demonstrating preserved system ownership.
The gallery only uses mock data and never authenticates or changes account state.

Also run existing `AllUIStatesShellCaptureUITests`,
`AllUIStatesWorkspacesCaptureUITests` and `AllUIStatesSurfacesCaptureUITests` for
real navigation placement: sidebar menu, team editor, connection banner,
command palette, workspace/pane menus, tab pickers, scanner and terminal/browser
surfaces. Those suites permit unreachable states: accept only `UISTATE-OK`, never
`UISTATE-MISS` or `uimiss` artifacts. Capture at normal and accessibility text
sizes and with Reduce Transparency enabled to check the system fallback.

Behavioral coverage to retain: `ToastRulesTests` (placement, duration, dismissal),
`CommandPaletteTests` (menu parity, search and once-only action dispatch after
dismissal), and onboarding flow tests. No behavioral redesign is intended.

## Evidence status

Source inventory and diff review only. No native build, test, screenshot or visual
selection receipt has been produced by the iOS implementation subtask. The owning
lane runs fleet verification and attaches exact-head before/after stills to the PR.
