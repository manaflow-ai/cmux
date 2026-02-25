# Changelog

All notable changes to cmux are documented here.

## [0.61.0] - 2026-02-25

### Added
- Command palette (Cmd+Shift+P) with update actions and all-window switcher results ([#358](https://github.com/manaflow-ai/cmux/pull/358), [#361](https://github.com/manaflow-ai/cmux/pull/361))
- Split actions and shortcut hints in terminal context menus
- Cross-window tab and workspace move UI with improved destination focus behavior
- Sidebar pull request metadata rows and workspace PR open actions
- Workspace color schemes and left-rail workspace indicator settings ([#324](https://github.com/manaflow-ai/cmux/pull/324), [#329](https://github.com/manaflow-ai/cmux/pull/329), [#332](https://github.com/manaflow-ai/cmux/pull/332))
- URL open-wrapper routing into the embedded browser ([#332](https://github.com/manaflow-ai/cmux/pull/332))
- Cmd+Q quit warning with suppression toggle ([#295](https://github.com/manaflow-ai/cmux/pull/295))
- `cmux --version` output now includes commit metadata

### Changed
- Added light mode and unified theme refresh across app surfaces ([#258](https://github.com/manaflow-ai/cmux/pull/258)) — thanks @ijpatricio for the report!
- Browser link middle-click handling now uses native WebKit behavior ([#416](https://github.com/manaflow-ai/cmux/pull/416))
- Settings-window actions now route through a single command-palette/settings flow
- Sentry upgraded with tracing, breadcrumbs, and dSYM upload support ([#366](https://github.com/manaflow-ai/cmux/pull/366))
- Session restore scope clarification: cmux restores layout, working directory, scrollback, and browser history, but does not resume live terminal process state yet

### Fixed
- Startup split hang when pressing Cmd+D then Ctrl+D early after launch ([#364](https://github.com/manaflow-ai/cmux/pull/364))
- Browser focus handoff and click-to-focus regressions in mixed terminal/browser workspaces ([#381](https://github.com/manaflow-ai/cmux/pull/381), [#355](https://github.com/manaflow-ai/cmux/pull/355))
- Caps Lock handling in browser omnibar keyboard paths ([#382](https://github.com/manaflow-ai/cmux/pull/382))
- Embedded browser deeplink URL scheme handling ([#392](https://github.com/manaflow-ai/cmux/pull/392))
- Sidebar resize cap regression ([#393](https://github.com/manaflow-ai/cmux/pull/393))
- Terminal zoom inheritance for new splits, surfaces, and workspaces ([#384](https://github.com/manaflow-ai/cmux/pull/384))
- Terminal find overlay layering across split and portal-hosted layouts
- Titlebar drag and double-click zoom handling on browser-side panes
- Stale browser favicon and window-title updates after navigation

### Thanks to 7 contributors!
- [@austinywang](https://github.com/austinywang)
- [@avisser](https://github.com/avisser)
- [@gnguralnick](https://github.com/gnguralnick)
- [@ijpatricio](https://github.com/ijpatricio)
- [@jperkin](https://github.com/jperkin)
- [@jungcome7](https://github.com/jungcome7)
- [@lawrencecchen](https://github.com/lawrencecchen)

## [0.60.0] - 2026-02-21

### Added
- Tab context menu with rename, close, unread, and workspace actions ([#225](https://github.com/manaflow-ai/cmux/pull/225))
- Cmd+Shift+T reopens closed browser panels ([#253](https://github.com/manaflow-ai/cmux/pull/253))
- Vertical sidebar branch layout setting showing git branch and directory per pane
- JavaScript alert/confirm/prompt dialogs in browser panel ([#237](https://github.com/manaflow-ai/cmux/pull/237))
- File drag-and-drop and file input in browser panel ([#214](https://github.com/manaflow-ai/cmux/pull/214))
- tmux-compatible command set with matrix tests ([#221](https://github.com/manaflow-ai/cmux/pull/221))
- Pane resize divider control via CLI ([#223](https://github.com/manaflow-ai/cmux/pull/223))
- Production read-screen capture APIs ([#219](https://github.com/manaflow-ai/cmux/pull/219))
- Notification rings on terminal panes ([#132](https://github.com/manaflow-ai/cmux/pull/132))
- Claude Code integration enabled by default ([#247](https://github.com/manaflow-ai/cmux/pull/247))
- HTTP host allowlist for embedded browser with save and proceed flow ([#206](https://github.com/manaflow-ai/cmux/pull/206), [#203](https://github.com/manaflow-ai/cmux/pull/203))
- Setting to disable workspace auto-reorder on notification ([#215](https://github.com/manaflow-ai/cmux/issues/205))
- Browser panel mouse back/forward buttons and middle-click close ([#139](https://github.com/manaflow-ai/cmux/pull/139))
- Browser DevTools shortcut wiring and persistence ([#117](https://github.com/manaflow-ai/cmux/pull/117))
- CJK IME input support for Korean, Chinese, and Japanese ([#125](https://github.com/manaflow-ai/cmux/pull/125))
- `--help` flag on CLI subcommands ([#128](https://github.com/manaflow-ai/cmux/pull/128))
- `--command` flag for `new-workspace` CLI command ([#121](https://github.com/manaflow-ai/cmux/pull/121))
- `rename-tab` socket command ([#260](https://github.com/manaflow-ai/cmux/pull/260))
- Remap-aware bonsplit tooltips and browser split shortcuts ([#200](https://github.com/manaflow-ai/cmux/pull/200))

### Fixed
- IME preedit anchor sizing ([#266](https://github.com/manaflow-ai/cmux/pull/266))
- Cmd+Shift+T focus against deferred stale callbacks ([#267](https://github.com/manaflow-ai/cmux/pull/267))
- Unknown Bonsplit tab context actions causing crash ([#264](https://github.com/manaflow-ai/cmux/pull/264))
- Socket CLI commands stealing macOS app focus ([#260](https://github.com/manaflow-ai/cmux/pull/260))
- CLI unix socket lag from main-thread blocking ([#259](https://github.com/manaflow-ai/cmux/pull/259))
- Main-thread notification cascade causing hangs ([#232](https://github.com/manaflow-ai/cmux/pull/232))
- Favicon out-of-sync during back/forward navigation ([#233](https://github.com/manaflow-ai/cmux/pull/233))
- Stale sidebar git branch after closing a split
- Browser download UX and crash path ([#235](https://github.com/manaflow-ai/cmux/pull/235))
- Browser reopen focus across workspace switches ([#257](https://github.com/manaflow-ai/cmux/pull/257))
- Mark Tab as Unread no-op on focused tab ([#249](https://github.com/manaflow-ai/cmux/pull/249))
- Split dividers disappearing in tiny panes ([#250](https://github.com/manaflow-ai/cmux/pull/250))
- Flaky browser download activity accounting ([#246](https://github.com/manaflow-ai/cmux/pull/246))
- Drag overlay routing and terminal overlay regressions ([#218](https://github.com/manaflow-ai/cmux/pull/218))
- Initial bonsplit split animation flicker
- Window top inset on new window creation ([#224](https://github.com/manaflow-ai/cmux/pull/224))
- Cmd+Enter being routed as browser reload ([#213](https://github.com/manaflow-ai/cmux/pull/213))
- Child-exit close for last-terminal workspaces ([#254](https://github.com/manaflow-ai/cmux/pull/254))
- Sidebar resizer hitbox and cursor across portals ([#255](https://github.com/manaflow-ai/cmux/pull/255))
- Workspace-scoped tab action resolution
- IDN host allowlist normalization
- `setup.sh` cache rebuild and stale lock timeout ([#217](https://github.com/manaflow-ai/cmux/pull/217))
- Inconsistent Tab/Workspace terminology in settings and menus ([#187](https://github.com/manaflow-ai/cmux/pull/187))

### Changed
- CLI workspace commands now run off the main thread for better responsiveness ([#270](https://github.com/manaflow-ai/cmux/pull/270))
- Remove border below titlebar ([#242](https://github.com/manaflow-ai/cmux/pull/242))
- Slimmer browser omnibar with button hover/press states ([#271](https://github.com/manaflow-ai/cmux/pull/271))
- Browser under-page background refreshes on theme updates ([#272](https://github.com/manaflow-ai/cmux/pull/272))
- Command shortcut hints scoped to active window ([#226](https://github.com/manaflow-ai/cmux/pull/226))
- Nightly and release assets are now immutable (no accidental overwrite) ([#268](https://github.com/manaflow-ai/cmux/pull/268), [#269](https://github.com/manaflow-ai/cmux/pull/269))

## [0.59.0] - 2026-02-19

### Fixed
- Fix panel resize hitbox being too narrow and stale portal frame after panel resize

## [0.58.0] - 2026-02-19

### Fixed
- Fix split blackout race condition and focus handoff when creating or closing splits

## [0.57.0] - 2026-02-19

### Added
- Terminal panes now show an animated drop overlay when dragging tabs

### Fixed
- Fix blue hover not showing when dragging tabs onto terminal panes
- Fix stale drag overlay blocking clicks after tab drag ends

## [0.56.0] - 2026-02-19

_No user-facing changes._

## [0.55.0] - 2026-02-19

### Changed
- Move port scanning from shell to app-side with batching for faster startup

### Fixed
- Fix visual stretch when closing split panes
- Fix omnibar Cmd+L focus races

## [0.54.0] - 2026-02-18

### Fixed
- Fix browser omnibar Cmd+L causing 100% CPU from infinite focus loop

## [0.53.0] - 2026-02-18

### Changed
- CLI commands are now workspace-relative: commands use `CMUX_WORKSPACE_ID` environment variable so background agents target their own workspace instead of the user's focused workspace
- Remove all index-based CLI APIs in favor of short ID refs (`surface:1`, `pane:2`, `workspace:3`)
- CLI `send` and `send-key` support `--workspace` and `--surface` flags for explicit targeting
- CLI escape sequences (`\n`, `\r`, `\t`) in `send` payloads are now handled correctly
- `--id-format` flag is respected in text output for all list commands

### Fixed
- Fix background agents sending input to the wrong workspace
- Fix `close-surface` rejecting cross-workspace surface refs
- Fix malformed surface/pane/workspace/window handles passing through without error
- Fix `--window` flag being overridden by `CMUX_WORKSPACE_ID` environment variable

## [0.52.0] - 2026-02-18

### Changed
- Faster workspace switching with reduced rendering churn

### Fixed
- Fix Finder file drop not reaching portal-hosted terminals
- Fix unfocused pane dimming not showing for portal-hosted terminals
- Fix terminal hit-testing and visual glitches during workspace teardown

## [0.51.0] - 2026-02-18

### Fixed
- Fix menubar and right-click lag on M1 Macs in release builds
- Fix browser panel opening new tabs on link click

## [0.50.0] - 2026-02-18

### Fixed
- Fix crashes and fatal error when dropping files from Finder
- Fix zsh git branch display not refreshing after changing directories
- Fix menubar and right-click lag on M1 Macs

## [0.49.0] - 2026-02-18

### Fixed
- Fix crash (stack overflow) when clicking after a Finder file drag
- Fix titlebar folder icon briefly enlarging on workspace switch

## [0.48.0] - 2026-02-18

### Fixed
- Fix right-click context menu lag in notarized builds by adding missing hardened runtime entitlements
- Fix claude shim conflicting with `--resume`, `--continue`, and `--session-id` flags

## [0.47.0] - 2026-02-18

### Fixed
- Fix sidebar tab drag-and-drop reordering not working

## [0.46.0] - 2026-02-18

### Fixed
- Fix broken mouse click forwarding in terminal views

## [0.45.0] - 2026-02-18

### Changed
- Rebuild with Xcode 26.2 and macOS 26.2 SDK

## [0.44.0] - 2026-02-18

### Fixed
- Crash caused by infinite recursion when clicking in terminal (FileDropOverlayView mouse event forwarding)

## [0.38.1] - 2026-02-18

### Fixed
- Right-click and menubar lag in production builds (rebuilt with macOS 26.2 SDK)

## [0.38.0] - 2026-02-18

### Added
- Double-clicking the sidebar title-bar area now zooms/maximizes the window

### Fixed
- Browser omnibar `Cmd+L` now reliably refreshes/selects-all and supports immediate typing without stale inline text
- Omnibar inline completion no longer replaces typed prefixes with mismatched suggestion text

## [0.37.0] - 2026-02-17

### Added
- "+" button on the tab bar for quickly creating new terminal or browser tabs

## [0.36.0] - 2026-02-17

### Fixed
- App hang when omnibar safety timeout failed to fire (blocked main thread)
- Tab drag/drop not working when multiple workspaces exist
- Clicking in browser WebView not focusing the browser tab

## [0.35.0] - 2026-02-17

### Fixed
- App hang when clicking browser omnibar (NSTextView tracking loop spinning forever)
- White flash when creating new browser panels
- Tab drag/drop broken when dragging over WebView panes
- Stale drag timeout cancelling new drags of the same tab
- 88% idle CPU from infinite makeFirstResponder loop
- Terminal keys (arrows, Ctrl+N/P) swallowed after opening browser
- Cmd+N swallowed by browser omnibar navigation
- Split focus stolen by re-entrant becomeFirstResponder during reparenting

## [0.34.0] - 2026-02-16

### Fixed
- Browser not loading localhost URLs correctly

## [0.33.0] - 2026-02-16

### Fixed
- Menubar and general UI lag in production builds
- Sidebar tabs getting extra left padding when update pill is visible
- Memory leak when middle-clicking to close tabs

## [0.32.0] - 2026-02-16

### Added
- Sidebar metadata: git branch, listening ports, log entries, progress bars, and status pills

### Fixed
- localhost and 127.0.0.1 URLs not resolving correctly in the browser panel

### Changed
- `browser open` now targets the caller's workspace by default via CMUX_WORKSPACE_ID

## [0.31.0] - 2026-02-15

### Added
- Arrow key navigation in browser omnibar suggestions
- Browser zoom shortcuts (Cmd+/-, Cmd+0 to reset)
- "Install Update and Relaunch" menu item when an update is available

### Changed
- Open browser shortcut remapped from Cmd+Shift+B to Cmd+Shift+L
- Flash focused panel shortcut remapped from Cmd+Shift+L to Cmd+Shift+H
- Update pill now shows only in the sidebar footer

### Fixed
- Omnibar inline completion showing partial domain (e.g. "news." instead of "news.ycombinator.com")

## [0.30.0] - 2026-02-15

### Fixed
- Update pill not appearing when sidebar is visible in Release builds

## [0.29.0] - 2026-02-15

### Added
- Cmd+click on links in the browser opens them in a new tab
- Right-click context menu shows "Open Link in New Tab" instead of "Open in New Window"
- Third-party licenses bundled in app with Licenses button in About window
- Update availability pill now visible in Release builds

### Changed
- Cmd+[/] now triggers browser back/forward when a browser panel is focused (no-op on terminal)
- Reload configuration shortcut changed to Cmd+Shift+,
- Improved browser omnibar suggestions and focus behavior

## [0.28.2] - 2026-02-14

### Fixed
- Sparkle updates from `0.27.0` could fail to detect newer releases because release build numbers were behind the latest published appcast build number
- Release GitHub Action failed on repeat runs when `SUPublicEDKey` / `SUFeedURL` already existed in `Info.plist`

## [0.28.1] - 2026-02-14

### Fixed
- Release build failure caused by debug-only helper symbols referenced in non-debug code paths

## [0.28.0] - 2026-02-14

### Added
- Optional nightly update channel in Settings (`Receive Nightly Builds`)
- Automated nightly build and publish workflow for `main` when new commits are available

### Changed
- Settings and About windows now use the updated transparent titlebar styling and aligned controls
- Repository license changed to GNU AGPLv3

### Fixed
- Terminal panes freezing after repeated split churn
- Finder service directory resolution now normalizes paths consistently

## [0.27.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items on macOS 14 (Sonoma) caused by `clipsToBounds` default change
- Toolbar buttons (sidebar, notifications, new tab) disappearing after toggling sidebar with Cmd+B
- Update check pill not appearing in titlebar on macOS 14 (Sonoma)

## [0.26.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items in focused window caused by background blur in themeFrame
- Sidebar showing two different textures near the titlebar on older macOS versions

## [0.25.0] - 2026-02-11

### Fixed
- Blank terminal on macOS 26 (Tahoe) — two additional code paths were still clearing the window background, bypassing the initial fix
- Blank terminal on macOS 15 caused by background blur view covering terminal content

## [0.24.0] - 2026-02-09

### Changed
- Update bundle identifier to `com.cmuxterm.app` for consistency

## [0.23.0] - 2026-02-09

### Changed
- Rename app to cmux — new app name, socket paths, Homebrew tap, and CLI binary name (bundle ID remains `com.cmuxterm.app` for Sparkle update continuity)
- Sidebar now shows tab status as text instead of colored dots, with instant git HEAD change detection

### Fixed
- CLI `set-status` command not properly quoting values or routing `--tab` flag

## [0.22.0] - 2026-02-09

### Fixed
- Xcode and system environment variables (e.g. DYLD, LANGUAGE) leaking into terminal sessions

## [0.21.0] - 2026-02-09

### Fixed
- Zsh autosuggestions not working with shared history across terminal panes

## [0.17.3] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle EdDSA signing was silently failing due to SUPublicEDKey missing from Info.plist)

## [0.17.1] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle public key was missing from release builds)

## [0.17.0] - 2025-02-05

### Fixed
- Traffic lights (close/minimize/zoom) not showing on macOS 13-15
- Titlebar content overlapping traffic lights and toolbar buttons when sidebar is hidden

## [0.16.0] - 2025-02-04

### Added
- Sidebar blur effect with withinWindow blending for a polished look
- `--panel` flag for `new-split` command to control split pane placement

## [0.15.0] - 2025-01-30

### Fixed
- Typing lag caused by redundant render loop

## [0.14.0] - 2025-01-30

### Added
- Setup script for initializing submodules and building dependencies
- Contributing guide for new contributors

### Fixed
- Terminal focus when scrolling with mouse/trackpad

### Changed
- Reload scripts are more robust with better error handling

## [0.13.0] - 2025-01-29

### Added
- Customizable keyboard shortcuts via Settings

### Fixed
- Find panel focus and search alignment with Ghostty behavior

### Changed
- Sentry environment now distinguishes between production and dev builds

## [0.12.0] - 2025-01-29

### Fixed
- Handle display scale changes when moving between monitors

### Changed
- Fix SwiftPM cache handling for release builds

## [0.11.0] - 2025-01-29

### Added
- Notifications documentation for AI agent integrations

### Changed
- App and tooling updates

## [0.10.0] - 2025-01-29

### Added
- Sentry SDK for crash reporting
- Documentation site with Fumadocs
- Homebrew installation support (`brew install --cask cmux`)
- Auto-update Homebrew cask on release

### Fixed
- High CPU usage from notification system
- Release workflow SwiftPM cache issues

### Changed
- New tabs now insert after current tab and inherit working directory

## [0.9.0] - 2025-01-29

### Changed
- Normalized window controls appearance
- Added confirmation panel when closing windows with active processes

## [0.8.0] - 2025-01-29

### Fixed
- Socket key input handling
- OSC 777 notification sequence support

### Changed
- Customized About window
- Restricted titlebar accessories for cleaner appearance

## [0.7.0] - 2025-01-29

### Fixed
- Environment variable and terminfo packaging issues
- XDG defaults handling

## [0.6.0] - 2025-01-28

### Fixed
- Terminfo packaging for proper terminal compatibility

## [0.5.0] - 2025-01-28

### Added
- Sparkle updater cache handling
- Ghostty fork documentation

## [0.4.0] - 2025-01-28

### Added
- cmux CLI with socket control modes
- NSPopover-based notifications

### Fixed
- Notarization and codesigning for embedded CLI
- Release workflow reliability

### Changed
- Refined titlebar controls and variants
- Clear notifications on window close

## [0.3.0] - 2025-01-28

### Added
- Debug scrollback tab with smooth scroll wheel
- Mock update feed UI tests
- Dev build branding and reload scripts

### Fixed
- Notification focus handling and indicators
- Tab focus for key input
- Update UI error details and pill visibility

### Changed
- Renamed app to cmux
- Improved CI UI test stability

## [0.1.0] - 2025-01-28

### Added
- Sparkle auto-update flow
- Titlebar update UI indicator

## [0.0.x] - 2025-01-28

Initial releases with core terminal functionality:
- GPU-accelerated terminal rendering via Ghostty
- Tab management with native macOS UI
- Split pane support
- Keyboard shortcuts
- Socket API for automation
