# New workspace and Connect your Mac: verification

Branch `feat-cnx-ios-wsnew`, 2026-10-13. Evidence is git-ignored, in
`verify/evidence/2026-10-13/wsnew/`.

User feedback:

- "making a new workspace should be instant with no form. holding on the new
  workspace button should provide other creation options in a picker."
- "scan qr code and enter code manually dont do anything in empty workspaces
  banner"

## What changed

### Instant creation (`CmuxMobileModel/WorkspaceCreation.swift`)

- The New Workspace sheet is gone. The toolbar button is a
  `Menu { … } primaryAction: { … }`, so a tap creates and a hold opens the menu,
  as with Safari's new-tab button and the Notes compose button.
- **A tap** creates a workspace on the preferred Mac, or on the only Mac that
  can take one. It starts with the Mac's default first tab, a terminal (cmux-tui
  `new-workspace` makes one screen, one pane and one terminal).
  - The directory is the last one used on that Mac, else `~`. In live mode the
    Mac picks: its home.
  - The title comes from the directory (or "New Workspace"). It is made unique
    on that Mac: "cmux 2", "New Workspace 3".
- **The state machine** is `WorkspaceCreator`.
  - `create` adds an optimistic row (`AppStore.insertPending`), and the list
    pushes it right away.
  - The backend then confirms or refuses. Phases: `pending`, `created(realID)`
    and `failed(message)`.
  - On success, `resolvePending` swaps the row for the real workspace. When
    the Mac gave it another id, the placeholder id becomes an alias, so the
    open screen follows the real workspace. That workspace opens on its first
    tab of the requested kind.
  - On a refusal, the row is removed. `ShellModel` pops the screen if it is
    open, shows the toast "Couldn't create a workspace on <Mac>", plays the
    error haptic, and logs the reason.
  - A tree refresh while a creation is in flight keeps the pending row
    (`replaceWorkspaces`).
  - The row shows "Creating…" and a spinner until the creation settles.
- **The hold menu** lists only what the backend supports on that Mac:
  - New Workspace
  - New Claude Workspace and New Codex Workspace (agent harnesses)
  - New Browser Workspace
  - Recent Directories (up to 5): the ones used from this phone first, then
    the Mac's workspaces by activity
  - Mac: a picker, shown only when more than one Mac can take a workspace

  The section header names the target Mac when there are several. Clone from
  git is modeled (`cloneFromGit`) but no backend supports it, so it is hidden.
- **Backends**:
  - `MockWorkspaceCreationBackend` offers every option except clone. Its
    600 ms latency runs on an injected clock. `failNext` makes the next
    creation fail, for the refusal demo.
  - `LiveWorkspaceCreationBackend` (CmuxMobileLive) works only on the linked,
    connected Mac. It offers the browser start only, because the
    `cmux-mobile-host` policy allows `new-workspace {name}` and `new-browser-tab`
    but refuses `cwd` and `new-conversation-tab`. So recent directories and
    agent first tabs are hidden in live mode.
    - It sends `new-workspace {name}`.
    - For a browser start, it then sends `new-browser-tab {url:"about:blank"}`
      into the new active pane. If that fails, the workspace keeps its
      terminal and opens on it.
    - `WorkspaceSync.listNow()` then lists at once and finds the workspace by
      the returned surface id.
    - A daemon error becomes the refusal.
- `WorkspaceTabsSource.activeTabID` is now derived: the chosen tab if it
  still exists, else the workspace's opening tab. This is needed when the
  placeholder's tab is replaced by the Mac's real tab.

### Connect your Mac (the Workspaces empty state and setup)

- Pairing is account based, so the dead "Scan QR code" and "Enter code
  manually" buttons are removed.
- `CmuxMobileDesign/ConnectMacSteps` shows two steps:
  1. "Open cmux on your Mac and sign in as <account email>."
  2. "In cmux on your Mac, turn on Settings → Mobile → Allow iPhone
     Connections." (Corrected from "Settings → iPhone" in `verify/pairing.md`:
     the Mac's section is Mobile.)
- Below the steps is a live status line. It reads "Waiting for your Mac…"
  with a spinner until presence reports a Mac, then "<Mac> is online" with a
  check.
- **Workspaces empty state** (`ConnectMacEmptyState`): presence swaps it for
  the list when the Mac appears. New Workspace is disabled while there is no
  Mac.
- **Setup step** (was "Set up cmux on your Mac"): shows "Not now" while
  waiting, and "Continue" once a Mac is online. "Email me a download link"
  only advanced the flow, with no backend behind it, so it was removed.

### No-op controls found and fixed (CmuxMobileWorkspaces, CmuxMobileOnboarding)

| Control | Was | Now |
| --- | --- | --- |
| Empty state "Scan QR code" | `primary: {}` | Removed (account-based pairing) |
| Empty state "Enter code manually" | `secondary: {}` | Removed |
| Setup "Email me a download link" | Advanced the flow | Removed (no backend) |
| Setup "I'm signed in on my Mac" | Advanced without checking | "Continue", shown once a Mac is online |
| Mac header menu "Pair Details" | `{}` | Removed |
| Mac header menu "Unpair" | `{}` | Removed (no unpair API) |
| Mac header menu "Reconnect" | `{}` | Live only: probes the linked Mac (`foreground()`) or dials that Mac (`select(macID:)`); the menu is hidden in mock mode and for offline Macs |
| List `.refreshable {}` | Spinner, nothing refreshed | Live only: `WorkspaceSync.refresh()`; no pull-to-refresh in mock mode |

The remaining empty closures in these modules are initializers and
`updateUIViewController` stubs.

### A crash found on the way (`CmuxMobileShell/GhosttyTerminalTabContent.swift`)

Leaving a workspace that was on a terminal tab, then pushing any workspace,
crashed SwiftUI with `AnyNavigationPath.Error.comparisonTypeMismatch`. The
cause was the terminal page's nested `NavigationStack`, which joined the
Workspaces stack's typed `[Workspace]` path.

- It reproduces without this change: open `ws-cmux` on `t-zsh`, go back, and
  push `ws-web`.
- Instant creation hit it on every second create, because new workspaces
  open on a terminal.
- `TerminalScreen` is now hosted in a UIKit `UINavigationController`
  (`TerminalNavigationHost`). The same repro survives, and so do both full
  demo runs.

## How it was verified

- **Unit tests** (Swift Testing). Built with `swift build --product <tests>`
  and run with `xcrun xctest` on macOS. A full `swift test` stops at the
  pre-existing `CmuxMobileTerminalTests` link failure (GhosttyKit symbols on macOS).
  - `CmuxMobileModelTests`: 20 passed, including 10 new `WorkspaceCreatorTests`:
    - an instant pending row that settles
    - a real workspace with its own id (alias, opening on the browser tab)
    - a tree refresh during creation (no lost row, no duplicate)
    - a refusal (row removed, `onFailure` reported)
    - no Mac
    - the preferred Mac
    - unsupported starts refused up front
    - directories only when the backend can choose them (defaults, recents,
      unique titles)
    - title rules
    - the mock backend failing once
  - `CmuxMobileLiveTests`: 24 passed, including 3 new `LiveWorkspaceCreationTests`
    against a fake daemon behind `MockMacLink`:
    - a tap sends `new-workspace {name}` and follows `wk2`, opening on `s10`
    - the browser start sends `new-browser-tab` and opens on `s11`
    - a policy refusal removes the placeholder
- **Recordings**: headless simulators `cmux-mobile-wsn-ios26` (iOS 26.5) and
  `cmux-mobile-wsn-ios27` (iOS 27.0), iPhone 17 Pro, dark mode, `CMUX_MOBILE_MOCK_AUTH=1`.
  Simulator.app was never opened.
  - `verify/record-wsnew.sh <udid> <label> [mode] [fps]` records the
    `-cmux-mobile-demo workspace-new` demo, streams the demo log and splits frames.
    The demo drives the real toolbar control:
    - The tap is `sendActions` on the bar button.
    - The hold is the button's own context-menu interaction, presented
      through its DEBUG-only present-at-location entry point.
    - A menu pick runs the same `creator.create` call that the menu item
      makes.
  - `verify/record-connect-mac.sh <udid> <label>` records the
    `-cmux-mobile-demo connect-mac` demo and the `-cmux-mobile-setup-pair` launch. Each one
    removes the Macs, then a Mac comes back 4 to 5 s in.

| Check | Result (iOS 26 and 27) | Evidence |
| --- | --- | --- |
| Tap | The push starts in the same frame as the tap, onto the new "New Workspace" terminal tab (`zsh`, `~`). Back shows the row at the top, "now", 1 tab | `ios26/sheet.png`, `ios26/frames/`, `ios27/` |
| Hold | The menu opens from the button: "On Aziz's Mac Studio", then New Workspace, New Claude Workspace, New Codex Workspace, New Browser Workspace, Recent Directories (Home, cmux, web), and Mac › | same |
| Pick Claude | Pushes "New Workspace 2" on a new Claude chat ("New session") | same |
| Refusal | The pushed "New Workspace 3" pops back, the toast "Couldn't create a workspace on Aziz's Mac Studio" appears, and the row is gone. The log has `refused: The Mac refused` | same, `*/app.log` |
| Connect your Mac (Workspaces) | Before: Scan QR code and Enter code manually. After: steps with the account email and "Waiting for your Mac…", then the list appears when the Mac does | `before-ios27/`, `after-ios2{6,7}/`, `connect-mac-before-after.png` |
| Connect your Mac (setup) | Before: "Set up cmux on your Mac" with three buttons. After: the same steps with "Not now", then "Aziz's Mac Studio is online" and Continue | same |

## Known gaps

- **Live creation has not been run against a real Mac.** It is covered only
  by the fake-daemon tests.
  - `new-workspace` makes the new workspace active on the daemon, which
    probably moves the Mac app's view.
  - Choosing another Mac in live mode needs the link to switch first, so the
    Mac picker lists only the linked Mac.
- **Agent first tabs and recent directories are mock only** until the phone
  lane allows `new-conversation-tab` and a reviewed `cwd`.
- **The terminal page in a workspace** shows no `TerminalScreen` toolbar, and
  its composer sits behind the TabsKit toolbar. That matches the
  "embedded variant still to come" note in `GhosttyTerminalTabContent`. It
  was not compared with a pre-change build, because the old `workspaces`
  demo no longer opens a workspace.
- **The hold uses a private UIKit entry point**, and only in DEBUG demos. A
  real long press needs a device or UI test.
- **Light mode** was not recorded.
