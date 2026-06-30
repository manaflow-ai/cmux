# Changelog

All notable changes to cmux are documented here.

## [0.64.17] - 2026-06-23

### Added
- Remote tmux mirroring over SSH using `-CC` control mode, in beta ([#5553](https://github.com/manaflow-ai/cmux/pull/5553)) -- thanks @robertnisipeanu!
- Global font magnification to scale the whole interface ([#6554](https://github.com/manaflow-ai/cmux/pull/6554))
- Right-sidebar custom sidebar tabs ([#6430](https://github.com/manaflow-ai/cmux/pull/6430))
- Chrome-style audio-playing indicator on browser panes ([#6517](https://github.com/manaflow-ai/cmux/pull/6517))
- Browser hard-refresh shortcut ([#6256](https://github.com/manaflow-ai/cmux/pull/6256))
- Clear Screen (Keep Scrollback) command, bound to Cmd+Shift+K ([#6139](https://github.com/manaflow-ai/cmux/pull/6139))
- Configurable terminal scroll-speed multiplier via `terminal.scrollSpeed` ([#5671](https://github.com/manaflow-ai/cmux/pull/5671)) -- thanks @RubiconPerform!
- Open the selected file from the keyboard in the file explorer ([#6001](https://github.com/manaflow-ai/cmux/pull/6001))
- One-step grouped workspace creation ([#6657](https://github.com/manaflow-ai/cmux/pull/6657))
- Searchable, uncapped diff viewer branch-base picker with smart defaults ([#6484](https://github.com/manaflow-ai/cmux/pull/6484)) -- thanks @azooz2003-bit!
- Mark workspaces read/unread and clear notifications from the workspace group menu ([#6535](https://github.com/manaflow-ai/cmux/pull/6535)) -- thanks @azooz2003-bit!
- Profiling capture action with a live progress window ([#6433](https://github.com/manaflow-ai/cmux/pull/6433), [#6440](https://github.com/manaflow-ai/cmux/pull/6440))
- `cmux remotes` CLI to manage device-registry routes ([#6096](https://github.com/manaflow-ai/cmux/pull/6096))
- Flag "Needs input" for blocked AskUserQuestion and ExitPlanMode prompts under `--dangerously-skip-permissions` ([#6608](https://github.com/manaflow-ai/cmux/pull/6608))
- iOS (beta): on-device voice dictation in the composer ([#6197](https://github.com/manaflow-ai/cmux/pull/6197))
- iOS (beta): image attachments in the composer ([#6102](https://github.com/manaflow-ai/cmux/pull/6102))
- iOS (beta): Return key on the terminal accessory bar ([#6101](https://github.com/manaflow-ai/cmux/pull/6101))
- iOS (beta): mark workspaces read/unread from the terminal menu, with an unread-count badge on the back button ([#6362](https://github.com/manaflow-ai/cmux/pull/6362), [#6350](https://github.com/manaflow-ai/cmux/pull/6350))

### Changed
- Terminal and browser surface tabs hug their content instead of stretching to a fixed width ([#6653](https://github.com/manaflow-ai/cmux/pull/6653))
- Prioritize full command-palette title matches over partial ones ([#6498](https://github.com/manaflow-ai/cmux/pull/6498))
- Reduce UI lag from Settings, sidebar, git, and browser churn ([#6260](https://github.com/manaflow-ai/cmux/pull/6260)) -- thanks @azooz2003-bit!
- Evict hidden browser WebViews under memory pressure and defer restored WebViews until visible ([#6585](https://github.com/manaflow-ai/cmux/pull/6585), [#6508](https://github.com/manaflow-ai/cmux/pull/6508))
- Gate idle pollers to the active workspace ([#6583](https://github.com/manaflow-ai/cmux/pull/6583))
- Diff viewer toolbar stays responsive and never overlaps at small widths ([#6550](https://github.com/manaflow-ai/cmux/pull/6550)) -- thanks @azooz2003-bit!
- Allow `.m4r` files as notification sounds ([#6635](https://github.com/manaflow-ai/cmux/pull/6635))
- iOS (beta): collapse workspace folders per device ([#6666](https://github.com/manaflow-ai/cmux/pull/6666))

### Fixed
- Fix a sidebar lag regression from v0.64.16 by cutting per-row font-modifier and pin-state work ([#6613](https://github.com/manaflow-ai/cmux/pull/6613))
- Fix the Codex sidebar status lifecycle and stale Claude notification sidebar status ([#6609](https://github.com/manaflow-ai/cmux/pull/6609), [#6473](https://github.com/manaflow-ai/cmux/pull/6473))
- Fix sidebar tab selection highlight timing ([#6627](https://github.com/manaflow-ai/cmux/pull/6627))
- Fix Cmd+T opening in home after an agent-resume session restore ([#6621](https://github.com/manaflow-ai/cmux/pull/6621))
- Fix explicit surface routing for read-screen and send ([#6605](https://github.com/manaflow-ai/cmux/pull/6605))
- Fix stale surface-to-panel rebinding and stale agent-resume executable paths ([#6581](https://github.com/manaflow-ai/cmux/pull/6581), [#6582](https://github.com/manaflow-ai/cmux/pull/6582))
- Fix terminal input after a window key restore ([#6518](https://github.com/manaflow-ai/cmux/pull/6518))
- Fix the Cmd+grave show/hide global hotkey ([#6477](https://github.com/manaflow-ai/cmux/pull/6477))
- Fix vim copy-mode cursor, V/Y selection, and pasteboard ([#6221](https://github.com/manaflow-ai/cmux/pull/6221))
- Fix copy-on-select parity with Ghostty ([#6200](https://github.com/manaflow-ai/cmux/pull/6200))
- Fix the crash-diagnostic window restore ([#6596](https://github.com/manaflow-ai/cmux/pull/6596))
- Fix a tab-switch crash in the vertical sidebar ([#6340](https://github.com/manaflow-ai/cmux/pull/6340))
- Fix a ~100% CPU re-render loop when selecting a bundled extension sidebar ([#6341](https://github.com/manaflow-ai/cmux/pull/6341))
- Fix blank SF Symbol controls on macOS 27 ([#6396](https://github.com/manaflow-ai/cmux/pull/6396))
- Fix the audio indicator audibility signal ([#6566](https://github.com/manaflow-ai/cmux/pull/6566))
- Fix browser download trigger parity ([#6258](https://github.com/manaflow-ai/cmux/pull/6258))
- Recover Settings opened from offscreen frames, and stop a closed Settings window from reappearing ([#5806](https://github.com/manaflow-ai/cmux/pull/5806), [#6193](https://github.com/manaflow-ai/cmux/pull/6193))
- Fix title-churn beachball in transcript adoption and sidebar rows ([#6460](https://github.com/manaflow-ai/cmux/pull/6460))
- Restore the pane header title after a terminal restart ([#6333](https://github.com/manaflow-ai/cmux/pull/6333))
- Recover a blank Markdown viewer pane after dragging it to another column ([#6331](https://github.com/manaflow-ai/cmux/pull/6331))
- Vault sidebar always offers "Show more" so capped folder sections stay reachable ([#6327](https://github.com/manaflow-ai/cmux/pull/6327))
- Fix the working directory after session-restore resume for Claude and other agents ([#6458](https://github.com/manaflow-ai/cmux/pull/6458), [#6205](https://github.com/manaflow-ai/cmux/pull/6205))
- Fix Claude Code 2.1.183 agent-team teammates opening split panes again ([#6499](https://github.com/manaflow-ai/cmux/pull/6499))
- Preserve Claude Teams restore flags ([#6242](https://github.com/manaflow-ai/cmux/pull/6242))
- Fix right-sidebar surface shortcut spam routing ([#6472](https://github.com/manaflow-ai/cmux/pull/6472))
- Fix Dia browser import profile detection ([#6478](https://github.com/manaflow-ai/cmux/pull/6478))
- Fix zsh aliases after the agent return shell ([#6515](https://github.com/manaflow-ai/cmux/pull/6515))
- Fix settings search for auto-naming and broaden fuzzy settings-search matching ([#6201](https://github.com/manaflow-ai/cmux/pull/6201), [#6196](https://github.com/manaflow-ai/cmux/pull/6196))
- Fix terminal focus retry after a tiny responder handoff ([#6359](https://github.com/manaflow-ai/cmux/pull/6359))
- Avoid DevTools teardown during redock ([#6559](https://github.com/manaflow-ai/cmux/pull/6559))
- Fix hidden popover relayout and reduce hit-test CPU during SwiftUI updates and pointer movement ([#6589](https://github.com/manaflow-ai/cmux/pull/6589), [#6592](https://github.com/manaflow-ai/cmux/pull/6592))
- Cache the settings search index per runtime ([#6591](https://github.com/manaflow-ai/cmux/pull/6591))
- Move the open-diff baseline lookup off the main thread ([#6497](https://github.com/manaflow-ai/cmux/pull/6497))
- Fix the macOS notification fallback identity ([#6000](https://github.com/manaflow-ai/cmux/pull/6000))
- Fix a remote PTY restore probe reply leak ([#6070](https://github.com/manaflow-ai/cmux/pull/6070))
- Fix OpenCode bunfs worker autoresume and OpenCode resume after a TUI-settings capture ([#6680](https://github.com/manaflow-ai/cmux/pull/6680), [#6397](https://github.com/manaflow-ai/cmux/pull/6397))
- Fix notification jump-focus for nested tabs ([#6416](https://github.com/manaflow-ai/cmux/pull/6416))
- Remove a sidebar rows measurement that re-livelocked layout at scale ([#6188](https://github.com/manaflow-ai/cmux/pull/6188))
- Prevent quit hangs from analytics flushing ([#6232](https://github.com/manaflow-ai/cmux/pull/6232), [#6417](https://github.com/manaflow-ai/cmux/pull/6417)) -- thanks @azooz2003-bit!
- Reduce Sentry CLI broken-pipe crashes and hangs ([#6254](https://github.com/manaflow-ai/cmux/pull/6254)) -- thanks @azooz2003-bit!
- Release closed macOS helper windows ([#6368](https://github.com/manaflow-ai/cmux/pull/6368)) -- thanks @azooz2003-bit!
- Fix canvas tab hover hit-testing, focus canvas panes from terminal body clicks, and fix canvas zoom-animation snap at low zoom ([#6555](https://github.com/manaflow-ai/cmux/pull/6555), [#6456](https://github.com/manaflow-ai/cmux/pull/6456), [#6538](https://github.com/manaflow-ai/cmux/pull/6538)) -- thanks @azooz2003-bit!
- Avoid nested quit-confirmation modal loops ([#6461](https://github.com/manaflow-ai/cmux/pull/6461)) -- thanks @azooz2003-bit!
- Reduce redundant panel title update work ([#6552](https://github.com/manaflow-ai/cmux/pull/6552)) -- thanks @Eridanus117!
- Fix a QuickLook preview crash on a deactivated QLPreviewView ([#6402](https://github.com/manaflow-ai/cmux/pull/6402)) -- thanks @thiveeiyan!
- Fix terminal content duplication on window resize ([#6386](https://github.com/manaflow-ai/cmux/pull/6386)) -- thanks @mvanhorn!
- Stop the main window drifting down on sleep/wake ([#6305](https://github.com/manaflow-ai/cmux/pull/6305)) -- thanks @sergej-koscejev!
- Fix stale cmux ssh pane resize by reconciling remote PTY size after arming SIGWINCH, and fix resize with SSH ControlMaster ([#5989](https://github.com/manaflow-ai/cmux/pull/5989), [#6432](https://github.com/manaflow-ai/cmux/pull/6432)) -- thanks @kylejcaron!
- Sync remote tmux session renames to the mirror workspace title, and fix session discovery under a non-UTF-8 remote locale ([#6602](https://github.com/manaflow-ai/cmux/pull/6602), [#6568](https://github.com/manaflow-ai/cmux/pull/6568)) -- thanks @mxschmitt!
- Fix the cmux ssh-tmux socket path being too long for AF_UNIX ([#6465](https://github.com/manaflow-ai/cmux/pull/6465)) -- thanks @mxschmitt!
- Fix remote-tmux mirror buffer truncation on a cross-DPI display move, and restore the bonsplit pointer so ssh-tmux tab reorders sync to tmux ([#6393](https://github.com/manaflow-ai/cmux/pull/6393), [#6438](https://github.com/manaflow-ai/cmux/pull/6438)) -- thanks @robertnisipeanu!
- Merge user `--settings` into injected hook settings in the claude wrapper ([#5388](https://github.com/manaflow-ai/cmux/pull/5388)) -- thanks @choi88andys!
- Bound iOS pairing attempts and fix the Pair iPhone window (Cmd+W, sizing, layout, QR padding, failure copy) ([#6495](https://github.com/manaflow-ai/cmux/pull/6495), [#6038](https://github.com/manaflow-ai/cmux/pull/6038))
- iOS (beta): fix native pairing sign-in failures ([#6457](https://github.com/manaflow-ai/cmux/pull/6457)) -- thanks @azooz2003-bit!
- iOS (beta): fix the unread count badge contrast, stop pausing background music on text submit, and sustain hold-to-repeat Backspace ([#6524](https://github.com/manaflow-ai/cmux/pull/6524), [#6290](https://github.com/manaflow-ai/cmux/pull/6290), [#6299](https://github.com/manaflow-ai/cmux/pull/6299))
- Fix the changelog title clipping ([#6425](https://github.com/manaflow-ai/cmux/pull/6425))

### Removed
- Remove the high-memory pane warning UI (the triangle indicator and popover); the underlying guardrail engine stays ([#6619](https://github.com/manaflow-ai/cmux/pull/6619))

### Thanks to 12 contributors!

- [@austinywang](https://github.com/austinywang)
- [@azooz2003-bit](https://github.com/azooz2003-bit)
- [@choi88andys](https://github.com/choi88andys)
- [@Eridanus117](https://github.com/Eridanus117)
- [@kylejcaron](https://github.com/kylejcaron)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@mvanhorn](https://github.com/mvanhorn)
- [@mxschmitt](https://github.com/mxschmitt)
- [@robertnisipeanu](https://github.com/robertnisipeanu)
- [@RubiconPerform](https://github.com/RubiconPerform)
- [@sergej-koscejev](https://github.com/sergej-koscejev)
- [@thiveeiyan](https://github.com/thiveeiyan)

## [0.64.16] - 2026-06-15

### Added
- Tab sidebar position setting: move the vertical tab list to the left or right side of the window ([#6389](https://github.com/manaflow-ai/cmux/pull/6389))
- Opt-in AI auto-naming of workspaces and tabs from your agent conversations ([#5547](https://github.com/manaflow-ai/cmux/pull/5547)) -- thanks @mvanhorn!
- Per-workspace environment variables inherited by every shell in the workspace ([#6116](https://github.com/manaflow-ai/cmux/pull/6116))
- Configurable file explorer double-click action: preview, default editor, or preferred editor ([#5827](https://github.com/manaflow-ai/cmux/pull/5827))
- Setting to hide modifier shortcut hints ([#6071](https://github.com/manaflow-ai/cmux/pull/6071))
- Configurable Dock max width ([#4385](https://github.com/manaflow-ai/cmux/pull/4385)) -- thanks @sort2f for the report!
- Customizable stable window title templates ([#6059](https://github.com/manaflow-ai/cmux/pull/6059)) -- thanks @digijoebz for the report!
- Diff language highlighting aliases ([#6076](https://github.com/manaflow-ai/cmux/pull/6076))
- Expose each workspace's custom title to the control socket for scripting ([#6013](https://github.com/manaflow-ai/cmux/pull/6013))
- iOS (beta): workspace list with groups, unread dots, last-activity previews, and a shared Unread filter ([#5726](https://github.com/manaflow-ai/cmux/pull/5726))
- iOS (beta): workspace row actions ([#6022](https://github.com/manaflow-ai/cmux/pull/6022)) -- thanks @azooz2003-bit!
- iOS (beta): Shift key on the terminal keyboard toolbar ([#6104](https://github.com/manaflow-ai/cmux/pull/6104))
- Experimental freeform 2D canvas layout for workspace panes, still in progress ([#5987](https://github.com/manaflow-ai/cmux/pull/5987)) -- thanks @azooz2003-bit!

### Changed
- macos-option-as-alt now honors left and right Option independently, sending sided modifier bits to the terminal ([#6007](https://github.com/manaflow-ai/cmux/pull/6007)) -- thanks @1nto5, @ucan-lab, @MrSpock, @Sancerro, @dreasan, @alceal, @lejahmie, and @tofunori for the reports!
- Gate remote SSH port scanning on the sidebar ports setting ([#6136](https://github.com/manaflow-ai/cmux/pull/6136)) -- thanks @Fail-Safe for the report!
- Polish the experimental canvas minimap navigation ([#6105](https://github.com/manaflow-ai/cmux/pull/6105)) -- thanks @azooz2003-bit!
- Make Codex agent hooks fire-and-forget so they never block the session ([#6110](https://github.com/manaflow-ai/cmux/pull/6110))
- Detect live claude/codex processes so hook-less agent sessions stay fork-able ([#6133](https://github.com/manaflow-ai/cmux/pull/6133))
- Stagger restored terminal surface spawns to smooth session restore ([#6149](https://github.com/manaflow-ai/cmux/pull/6149))
- Reclaim offscreen terminal renderer GPU memory (IOSurface) non-destructively ([#5857](https://github.com/manaflow-ai/cmux/pull/5857))
- iOS (beta): smoother terminal scrolling with local scrollback prefetch and faster scroll rendering ([#6067](https://github.com/manaflow-ai/cmux/pull/6067), [#6035](https://github.com/manaflow-ai/cmux/pull/6035)) -- thanks @azooz2003-bit!
- iOS (beta): cross-device notification dismiss-sync and an authoritative unread badge ([#5916](https://github.com/manaflow-ai/cmux/pull/5916))
- iOS (beta): local-first, offline-safe sign-out ([#5776](https://github.com/manaflow-ai/cmux/pull/5776))
- iOS (beta): require a matching email for pairing ([#6028](https://github.com/manaflow-ai/cmux/pull/6028))

### Fixed
- Fix terminal top-row mouse event routing, including minimal-UI hit testing ([#4391](https://github.com/manaflow-ai/cmux/pull/4391), [#6073](https://github.com/manaflow-ai/cmux/pull/6073)) -- thanks @colangelo and @edouardp for the reports!
- Restore OSC 11 pane-local backgrounds ([#5997](https://github.com/manaflow-ai/cmux/pull/5997)) -- thanks @fkchang for the report!
- Fix the macOS 27 SF Symbol rasterization crash ([#5999](https://github.com/manaflow-ai/cmux/pull/5999)) -- thanks @matheustimbo and @joseluislucio for the reports!
- Fix a stale Metal drawable after terminal layer realization ([#6057](https://github.com/manaflow-ai/cmux/pull/6057)) -- thanks @robertnisipeanu for the report!
- Fix terminal arrow key routing for TUI model selection ([#6002](https://github.com/manaflow-ai/cmux/pull/6002)) -- thanks @wo4wangle for the report!
- Fix the Cmd+T working directory after session restore ([#6055](https://github.com/manaflow-ai/cmux/pull/6055)) -- thanks @WangRouna for the report!
- Preserve Pi sessions across workspace restore ([#5607](https://github.com/manaflow-ai/cmux/pull/5607)) -- thanks @bjesuiter for the report!
- Fix top-right titlebar drag chrome ([#6003](https://github.com/manaflow-ai/cmux/pull/6003)) -- thanks @dbachelder for the report!
- Fix the OpenWrt BusyBox remote platform probe ([#6056](https://github.com/manaflow-ai/cmux/pull/6056)) -- thanks @Fail-Safe for the report!
- Fix stale remote connected state after a proxy disconnect ([#4513](https://github.com/manaflow-ai/cmux/pull/4513))
- Surface a browser fallback when Safari sign-in hangs ([#6113](https://github.com/manaflow-ai/cmux/pull/6113))
- Fix the browser omnibar Return submitting stale text during fast typing ([#5923](https://github.com/manaflow-ai/cmux/pull/5923))
- Avoid mirroring web proxies as CONNECT ([#5959](https://github.com/manaflow-ai/cmux/pull/5959))
- Fall back to SSH when the Cloud VM attach endpoint is unavailable ([#6079](https://github.com/manaflow-ai/cmux/pull/6079))
- Fix sidebar row-height layout feedback ([#6111](https://github.com/manaflow-ai/cmux/pull/6111))
- Kill a sidebar LazyVStack layout livelock ([#6033](https://github.com/manaflow-ai/cmux/pull/6033)) -- thanks @azooz2003-bit!
- Fix unexpected menu-bar-only activation policy ([#6068](https://github.com/manaflow-ai/cmux/pull/6068))
- Fix Mermaid diagrams scaling in the markdown viewer zoom ([#6072](https://github.com/manaflow-ai/cmux/pull/6072))
- Honor Focus / Do Not Disturb for the fallback notification sound ([#5651](https://github.com/manaflow-ai/cmux/pull/5651)) -- thanks @Reebz!
- iOS (beta): fix compact workspace row navigation by removing redundant tap gestures ([#6124](https://github.com/manaflow-ai/cmux/pull/6124)) -- thanks @azooz2003-bit!
- iOS (beta): reduce workspace row swipe contention ([#6064](https://github.com/manaflow-ai/cmux/pull/6064)) -- thanks @azooz2003-bit!
- iOS (beta): fix a workspace swipe-delete confirmation crash ([#6051](https://github.com/manaflow-ai/cmux/pull/6051)) -- thanks @azooz2003-bit!
- iOS (beta): preserve the email code sign-in nonce ([#6097](https://github.com/manaflow-ai/cmux/pull/6097))
- iOS (beta): fix TestFlight push notifications by exporting the production APNs entitlement ([#6131](https://github.com/manaflow-ai/cmux/pull/6131))

### Thanks to 26 contributors!

- [@1nto5](https://github.com/1nto5)
- [@alceal](https://github.com/alceal)
- [@austinywang](https://github.com/austinywang)
- [@azooz2003-bit](https://github.com/azooz2003-bit)
- [@bjesuiter](https://github.com/bjesuiter)
- [@colangelo](https://github.com/colangelo)
- [@dbachelder](https://github.com/dbachelder)
- [@digijoebz](https://github.com/digijoebz)
- [@dreasan](https://github.com/dreasan)
- [@edouardp](https://github.com/edouardp)
- [@Fail-Safe](https://github.com/Fail-Safe)
- [@fkchang](https://github.com/fkchang)
- [@joseluislucio](https://github.com/joseluislucio)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@lejahmie](https://github.com/lejahmie)
- [@matheustimbo](https://github.com/matheustimbo)
- [@MrSpock](https://github.com/MrSpock)
- [@mvanhorn](https://github.com/mvanhorn)
- [@Reebz](https://github.com/Reebz)
- [@robertnisipeanu](https://github.com/robertnisipeanu)
- [@Sancerro](https://github.com/Sancerro)
- [@sort2f](https://github.com/sort2f)
- [@tofunori](https://github.com/tofunori)
- [@ucan-lab](https://github.com/ucan-lab)
- [@WangRouna](https://github.com/WangRouna)
- [@wo4wangle](https://github.com/wo4wangle)

## [0.64.15] - 2026-06-12

### Added
- Review comments in the diff viewer: comment on changed lines, persisted per repo, and attach the comment set to a terminal TextBox to hand to an agent ([#5768](https://github.com/manaflow-ai/cmux/pull/5768))
- `when` context clauses for keyboard shortcuts with VS Code-style context keys and operators, and the Select Workspace/Surface 1…9 shortcuts (⌘1–9) are now rebindable ([#5196](https://github.com/manaflow-ai/cmux/pull/5196))
- New Browser Workspace command (Option+Cmd+N) ([#5926](https://github.com/manaflow-ai/cmux/pull/5926))
- Browser view actions in the CLI (react-grab, devtools, console, focus-mode, zoom, history) with a more reliable automation lane ([#5766](https://github.com/manaflow-ai/cmux/pull/5766), [#5778](https://github.com/manaflow-ai/cmux/pull/5778))
- `cmux window display` to place a window on a named display ([#5804](https://github.com/manaflow-ai/cmux/pull/5804)) -- thanks @azooz2003-bit!
- Workspace group commands in the cloud CLI relay ([#5856](https://github.com/manaflow-ai/cmux/pull/5856)) -- thanks @azooz2003-bit!
- Fish shell integration ([#5678](https://github.com/manaflow-ai/cmux/pull/5678))
- React and Solid agent session panels ([#4429](https://github.com/manaflow-ai/cmux/pull/4429))
- iOS (beta): iMessage-style terminal composer with inline send and per-terminal drafts, plus a View as Text sheet for copying terminal output ([#5876](https://github.com/manaflow-ai/cmux/pull/5876), [#5875](https://github.com/manaflow-ai/cmux/pull/5875))
- iOS (beta): customizable terminal toolbar with custom actions and reorderable built-ins, on a redesigned default layout ([#5510](https://github.com/manaflow-ai/cmux/pull/5510), [#5579](https://github.com/manaflow-ai/cmux/pull/5579), [#5532](https://github.com/manaflow-ai/cmux/pull/5532))
- iOS (beta): multi-Mac host switcher with a hierarchical device tree, workspaces from all Mac windows, and rename/pin from the phone ([#5513](https://github.com/manaflow-ai/cmux/pull/5513), [#5648](https://github.com/manaflow-ai/cmux/pull/5648), [#5565](https://github.com/manaflow-ai/cmux/pull/5565), [#5512](https://github.com/manaflow-ai/cmux/pull/5512))
- iOS (beta): paste images from the phone clipboard into the terminal ([#5546](https://github.com/manaflow-ai/cmux/pull/5546))
- iOS (beta): first-run onboarding, Tailscale-off detection, actionable pairing failures, cancellable sign-in, and pull-to-refresh on the workspace list ([#5655](https://github.com/manaflow-ai/cmux/pull/5655), [#5714](https://github.com/manaflow-ai/cmux/pull/5714), [#5722](https://github.com/manaflow-ai/cmux/pull/5722), [#5713](https://github.com/manaflow-ai/cmux/pull/5713), [#5728](https://github.com/manaflow-ai/cmux/pull/5728), [#5654](https://github.com/manaflow-ai/cmux/pull/5654))
- iOS (beta): early browser panes (WKWebView) and a Send Feedback flow ([#5652](https://github.com/manaflow-ai/cmux/pull/5652), [#5653](https://github.com/manaflow-ai/cmux/pull/5653))

### Changed
- Custom sidebars render in-process by default, get a dedicated Settings section, remount instantly on toggle, and repaint live during resize, with new example sidebars to start from ([#5867](https://github.com/manaflow-ai/cmux/pull/5867), [#5864](https://github.com/manaflow-ai/cmux/pull/5864), [#5895](https://github.com/manaflow-ai/cmux/pull/5895)) -- thanks @azooz2003-bit!
- Terminal notifications forward to the iPhone only while you're away from the Mac ([#5912](https://github.com/manaflow-ai/cmux/pull/5912))
- Slimmer pairing QR codes that scan faster, with Copy IP/Port and no expiry ([#5727](https://github.com/manaflow-ai/cmux/pull/5727), [#5872](https://github.com/manaflow-ai/cmux/pull/5872))
- The Mac pairing window shows a connected state when the iPhone attaches ([#5542](https://github.com/manaflow-ai/cmux/pull/5542), [#5795](https://github.com/manaflow-ai/cmux/pull/5795))
- Crash reports scrub file paths, PII, and secrets before sending ([#5598](https://github.com/manaflow-ai/cmux/pull/5598))
- Webview assets are split per surface so panes load less JavaScript ([#5613](https://github.com/manaflow-ai/cmux/pull/5613))

### Fixed
- Fix the app hanging at 100% CPU on launch on macOS 26 from a FileExplorer SwiftUI update loop ([#5786](https://github.com/manaflow-ai/cmux/pull/5786), [#4937](https://github.com/manaflow-ai/cmux/pull/4937)) -- thanks @kevinsslin, and @haoranaaa for the report!
- Fix a launch crash on the macOS 27 beta and unblock Xcode 27 builds ([#5670](https://github.com/manaflow-ai/cmux/pull/5670)) -- thanks @matheustimbo!
- Fix SSH typing lag with async PTY writes ([#5594](https://github.com/manaflow-ai/cmux/pull/5594)) -- thanks @lleewwiiss!
- Fix light themes rendering white-on-white terminals ([#5826](https://github.com/manaflow-ai/cmux/pull/5826)) -- thanks @abdullahnauman2 for the report!
- Hide the sidebar scrollbar when content fits and fade the overlay knob when idle ([#4767](https://github.com/manaflow-ai/cmux/pull/4767), [#5846](https://github.com/manaflow-ai/cmux/pull/5846), [#5955](https://github.com/manaflow-ai/cmux/pull/5955)) -- thanks @yigitkonur for the report!
- Fix recurring main-thread livelocks with many workspaces and agent sessions, and a UI freeze when closing tabs ([#5708](https://github.com/manaflow-ai/cmux/pull/5708), [#5859](https://github.com/manaflow-ai/cmux/pull/5859), [#5673](https://github.com/manaflow-ai/cmux/pull/5673), [#5669](https://github.com/manaflow-ai/cmux/pull/5669))
- Cmd-click links inside fullscreen TUIs (Claude, Codex) now open in cmux's browser instead of the system default ([#5406](https://github.com/manaflow-ai/cmux/pull/5406)) -- thanks @denysshnurenko for the report!
- Fix OSC 8 Cmd-click hyperlinks in terminal panes ([#3580](https://github.com/manaflow-ai/cmux/pull/3580))
- Surface needs-input attention (sidebar status, bell, tab elevation) for blocking PermissionRequest hook decisions ([#5313](https://github.com/manaflow-ai/cmux/pull/5313)) -- thanks @Dukeman330 for the report!
- Fix resumed Claude sessions dropping cmux hooks when `claude` doesn't resolve to the wrapper ([#5721](https://github.com/manaflow-ai/cmux/pull/5721)) -- thanks @Lipdog for the report!
- Preserve user Claude settings on resume ([#5661](https://github.com/manaflow-ai/cmux/pull/5661))
- Fix forked Claude sessions restoring the parent session after a cmux restart, and restore missing Fork Conversation entries ([#5910](https://github.com/manaflow-ai/cmux/pull/5910), [#5937](https://github.com/manaflow-ai/cmux/pull/5937))
- Recover session restore from a corrupt snapshot via the rolling backup ([#5914](https://github.com/manaflow-ai/cmux/pull/5914))
- Keep Codex permission hooks non-blocking ([#5507](https://github.com/manaflow-ai/cmux/pull/5507))
- Browser: fix the context menu opening the wrong link, wrong image download filenames, and loopback URLs hitting the system proxy on local workspaces ([#5780](https://github.com/manaflow-ai/cmux/pull/5780), [#5938](https://github.com/manaflow-ai/cmux/pull/5938), [#5915](https://github.com/manaflow-ai/cmux/pull/5915))
- Fix a browser keyDown stack-overflow crash ([#5899](https://github.com/manaflow-ai/cmux/pull/5899)) -- thanks @azooz2003-bit!
- Fix crashes from key-routing replay loops in the find overlay and browser ([#5755](https://github.com/manaflow-ai/cmux/pull/5755), [#5891](https://github.com/manaflow-ai/cmux/pull/5891))
- Fix the Find pane for same-directory workspaces ([#5956](https://github.com/manaflow-ai/cmux/pull/5956))
- Stop SSH auto-reconnect when the host is unreachable and add a manual Reconnect control ([#5767](https://github.com/manaflow-ai/cmux/pull/5767))
- Keep remote shell startup responsive ([#5695](https://github.com/manaflow-ai/cmux/pull/5695))
- Stop titlebar elements shifting when toggling the sidebar ([#5707](https://github.com/manaflow-ai/cmux/pull/5707)) -- thanks @azooz2003-bit!
- Localize package display strings missing from the app catalogs ([#5829](https://github.com/manaflow-ai/cmux/pull/5829)) -- thanks @azooz2003-bit!
- Clearer updater errors when the launchd agent install fails, with a manual-download fallback ([#5760](https://github.com/manaflow-ai/cmux/pull/5760)) -- thanks @azooz2003-bit!
- Retain the Settings window so it reliably reopens ([#5801](https://github.com/manaflow-ai/cmux/pull/5801)) -- thanks @azooz2003-bit!
- Fix the diff viewer loading state showing gray instead of the terminal theme ([#5631](https://github.com/manaflow-ai/cmux/pull/5631))
- Fix the inline VS Code command palette and WebSocket startup ([#5595](https://github.com/manaflow-ai/cmux/pull/5595))
- Fix sidebar Shift-click range selection after a no-op drag ([#5601](https://github.com/manaflow-ai/cmux/pull/5601))
- Keep pinned workspaces inside their group, and fix dragging grouped workspaces above their group ([#5541](https://github.com/manaflow-ai/cmux/pull/5541), [#5612](https://github.com/manaflow-ai/cmux/pull/5612))
- Fix sidebar status pills for newly created workspaces ([#5662](https://github.com/manaflow-ai/cmux/pull/5662))
- Don't hijack ZDOTDIR when the bundled shell-integration bootstrap is missing ([#5773](https://github.com/manaflow-ai/cmux/pull/5773))
- Fix memory growth from retained publish responses and event-stream allocations ([#5664](https://github.com/manaflow-ai/cmux/pull/5664))
- Reduce background CPU from process polling and browser-availability checks ([#5759](https://github.com/manaflow-ai/cmux/pull/5759), [#5744](https://github.com/manaflow-ai/cmux/pull/5744))
- iOS (beta): park notification-tap deep links until the workspace can be opened, fix a false-fire render watchdog replay loop, cap the restoring-session wait for stale Macs, and localize push notification strings ([#5927](https://github.com/manaflow-ai/cmux/pull/5927), [#5869](https://github.com/manaflow-ai/cmux/pull/5869), [#5564](https://github.com/manaflow-ai/cmux/pull/5564), [#5519](https://github.com/manaflow-ai/cmux/pull/5519))

### Thanks to 12 contributors!

- [@abdullahnauman2](https://github.com/abdullahnauman2)
- [@austinywang](https://github.com/austinywang)
- [@azooz2003-bit](https://github.com/azooz2003-bit)
- [@denysshnurenko](https://github.com/denysshnurenko)
- [@Dukeman330](https://github.com/Dukeman330)
- [@haoranaaa](https://github.com/haoranaaa)
- [@kevinsslin](https://github.com/kevinsslin)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@Lipdog](https://github.com/Lipdog)
- [@lleewwiiss](https://github.com/lleewwiiss)
- [@matheustimbo](https://github.com/matheustimbo)
- [@yigitkonur](https://github.com/yigitkonur)

## [0.64.14] - 2026-06-06

### Added
- iPhone companion app (beta): pair an iPhone from the new Mobile Connect window (also in the command palette) and attach to your Mac's terminals from your phone, with a configurable pairing port and opt-in forwarding of terminal notifications; the iOS beta ships on TestFlight as cmux BETA ([#5079](https://github.com/manaflow-ai/cmux/pull/5079), [#5493](https://github.com/manaflow-ai/cmux/pull/5493), [#5489](https://github.com/manaflow-ai/cmux/pull/5489), [#5518](https://github.com/manaflow-ai/cmux/pull/5518))
- Drag a workspace into another window's sidebar to move it between windows, including grouped workspaces ([#5399](https://github.com/manaflow-ai/cmux/pull/5399))
- Sign In and Sign Out commands in the command palette ([#5529](https://github.com/manaflow-ai/cmux/pull/5529))
- OMP agent hook integration with notifications and session restore via `cmux hooks omp` ([#5413](https://github.com/manaflow-ai/cmux/pull/5413)) -- thanks @joshrzemien!

### Changed
- Custom sidebar extensions now run out-of-process with an isolated interpreter, so a broken sidebar can't hang or crash the app ([#5294](https://github.com/manaflow-ai/cmux/pull/5294), [#5382](https://github.com/manaflow-ai/cmux/pull/5382)) -- thanks @azooz2003-bit!
- Broader SwiftUI primitive coverage in the custom sidebar interpreter ([#5275](https://github.com/manaflow-ai/cmux/pull/5275)) -- thanks @azooz2003-bit!
- Browser omnibar: the first click that focuses the address bar selects the whole URL, later clicks place the caret (Chrome parity) ([#5462](https://github.com/manaflow-ai/cmux/pull/5462), [#5352](https://github.com/manaflow-ai/cmux/pull/5352))
- Browser chrome (omnibar font and toolbar icons) scales with the tab bar font size ([#5464](https://github.com/manaflow-ai/cmux/pull/5464))
- Sidebar workspace group headers scale with the sidebar font size ([#5401](https://github.com/manaflow-ai/cmux/pull/5401))
- Agent Hibernation defaults to a 5-second idle window when enabled ([#5449](https://github.com/manaflow-ai/cmux/pull/5449))
- Tighter fuzzy filtering for skill suggestions in the terminal textbox ([#5348](https://github.com/manaflow-ai/cmux/pull/5348))

### Fixed
- Keep actively-playing audio and video in browser panes alive when the pane is hidden ([#5412](https://github.com/manaflow-ai/cmux/pull/5412), [#5441](https://github.com/manaflow-ai/cmux/pull/5441))
- Fix a typing beachball in the browser omnibar with large browsing histories ([#5397](https://github.com/manaflow-ai/cmux/pull/5397))
- Fix the main window refusing to resize narrower than its current width ([#5474](https://github.com/manaflow-ai/cmux/pull/5474))
- Fix the sidebar close button hidden under wrapped workspace titles ([#5488](https://github.com/manaflow-ai/cmux/pull/5488))
- Fix notification sound selection so the picker previews the selected sound and notifications play it ([#5480](https://github.com/manaflow-ai/cmux/pull/5480))
- Restore the menu bar icon dropdown menu on click ([#5451](https://github.com/manaflow-ai/cmux/pull/5451))
- Fix OSC control sequences (e.g. terminal background color) printed as literal text when sent via `cmux send` ([#5509](https://github.com/manaflow-ai/cmux/pull/5509))
- Fix native Claude resume dropping cmux hooks, so notifications and status tracking keep working on resumed sessions ([#5430](https://github.com/manaflow-ai/cmux/pull/5430))
- Fix Agent Hibernation for node-backed Claude sessions ([#5433](https://github.com/manaflow-ai/cmux/pull/5433))
- Codex resume hardening: keep restored surfaces from jumbling and preserve `CODEX_HOME` so non-default Codex homes resume correctly ([#5351](https://github.com/manaflow-ai/cmux/pull/5351))
- Fix Cmd +/- zoom in the browser and Markdown viewer on non-US keyboard layouts ([#5394](https://github.com/manaflow-ai/cmux/pull/5394))
- Preserve syntax highlighting on changed lines in the diff viewer ([#5415](https://github.com/manaflow-ai/cmux/pull/5415))
- Fix a stale group name in the window title bar after renaming a workspace group ([#5408](https://github.com/manaflow-ai/cmux/pull/5408))
- Fix the Dock sidebar not rendering after closing and reopening it ([#5437](https://github.com/manaflow-ai/cmux/pull/5437))
- Fix OMO subagent pane respawn through the tmux compatibility shim ([#5465](https://github.com/manaflow-ai/cmux/pull/5465)) -- thanks @leodiegoo for the report!
- Reduce sidebar git activity by coalescing repeated metadata probes ([#5402](https://github.com/manaflow-ai/cmux/pull/5402))

### Thanks to 5 contributors!

- [@austinywang](https://github.com/austinywang)
- [@azooz2003-bit](https://github.com/azooz2003-bit)
- [@joshrzemien](https://github.com/joshrzemien)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@leodiegoo](https://github.com/leodiegoo)

## [0.64.13] - 2026-06-04

### Added
- Browser focus mode ([#4573](https://github.com/manaflow-ai/cmux/pull/4573))
- SSH agent forwarding for `cmux ssh`, so remote sessions can use your local SSH keys ([#5301](https://github.com/manaflow-ai/cmux/pull/5301))
- Vibe-codable custom sidebars: a runtime Swift interpreter for building your own sidebar, behind a Beta Features flag, with CLI validation and live reload ([#5254](https://github.com/manaflow-ai/cmux/pull/5254), [#5327](https://github.com/manaflow-ai/cmux/pull/5327)) -- thanks @azooz2003-bit!
- Browser mouse back and forward button support ([#5197](https://github.com/manaflow-ai/cmux/pull/5197))
- Persisted word-wrap setting for the file editor ([#5247](https://github.com/manaflow-ai/cmux/pull/5247))
- "Open Current Directory in Devin" command ([#5288](https://github.com/manaflow-ai/cmux/pull/5288)) -- thanks @MaxiAschenbrenner!
- Live status reporting in the Amp Neo session plugin, driving the cmux tab status bar ([#5235](https://github.com/manaflow-ai/cmux/pull/5235)) -- thanks @HamptonMakes!

### Changed
- Anchor the textbox autocomplete to the cursor ([#5021](https://github.com/manaflow-ai/cmux/pull/5021))
- Add a font-size popover to the Markdown viewer controls ([#5168](https://github.com/manaflow-ai/cmux/pull/5168))
- Open group config files in your configured editor ([#5250](https://github.com/manaflow-ai/cmux/pull/5250))
- Isolate browser WebKit process pools so one browser pane crashing no longer takes down the others ([#4987](https://github.com/manaflow-ai/cmux/pull/4987))
- Move large scrollback read-text work off the main actor to reduce UI hangs ([#5243](https://github.com/manaflow-ai/cmux/pull/5243)) -- thanks @azooz2003-bit!

### Fixed
- Fix a settings-observation task leak that grew the app process to 4.4 GB over ~23h ([#5310](https://github.com/manaflow-ai/cmux/pull/5310))
- Fix a browser pane render loop that re-navigated the WebView on every CoreAnimation commit (~39% main-thread CPU) ([#5311](https://github.com/manaflow-ai/cmux/pull/5311))
- Fix a WebKit post-wake crash with sleep/wake-aware hidden-webview discard scheduling ([#5315](https://github.com/manaflow-ai/cmux/pull/5315)) -- thanks @azooz2003-bit!
- Fix the Markdown and file-preview text editor hanging at 100% CPU on click or drag-select by forcing a TextKit 1 stack ([#5257](https://github.com/manaflow-ai/cmux/pull/5257))
- Stop cmux from launching child processes under Rosetta on Apple Silicon ([#5306](https://github.com/manaflow-ai/cmux/pull/5306)) -- thanks @CharlesWiltgen for the report!
- Recover terminal focus when the first responder is stranded in another window ([#5296](https://github.com/manaflow-ai/cmux/pull/5296))
- Fix the browser address bar so a single click places a caret instead of selecting the whole URL ([#5270](https://github.com/manaflow-ai/cmux/pull/5270))
- Fix copy-mode vim keys (j/k/h/l) swallowed under non-ASCII input sources (Korean, Japanese Kana, Zhuyin) ([#5292](https://github.com/manaflow-ai/cmux/pull/5292)) -- thanks @pstanton237!
- Fix terminal copy-mode cursor navigation ([#5328](https://github.com/manaflow-ai/cmux/pull/5328))
- Fix terminal selection on mouse-up while the find overlay is open ([#5335](https://github.com/manaflow-ai/cmux/pull/5335))
- Fix TextBox IME and input-source handling ([#5340](https://github.com/manaflow-ai/cmux/pull/5340))
- Fix the macOS "wants to access data from other apps" prompt on agent session start and quit by moving the control socket out of Application Support ([#5176](https://github.com/manaflow-ai/cmux/pull/5176))
- Fix Codex auto-resume emitting an invalid `-s disabled` sandbox flag ([#5276](https://github.com/manaflow-ai/cmux/pull/5276)) -- thanks @taonetm7 for the report!
- Fix agent session resume cd-ing into the wrong directory after a cwd drift, plus post-kill cwd handling ([#5300](https://github.com/manaflow-ai/cmux/pull/5300), [#5312](https://github.com/manaflow-ai/cmux/pull/5312))
- Fix restored cwd bindings after a reboot ([#5307](https://github.com/manaflow-ai/cmux/pull/5307))
- Fix a stale sidebar git branch after cd-ing out of a repo into a non-git directory ([#5279](https://github.com/manaflow-ai/cmux/pull/5279))
- Fix a TextBox teardown crash when toggling the sidebar background ([#5317](https://github.com/manaflow-ai/cmux/pull/5317))
- Fix a workspace-close teardown hang ([#5316](https://github.com/manaflow-ai/cmux/pull/5316)) -- thanks @azooz2003-bit!
- Fix the workspace-group "Delete Group" context-menu action being a no-op ([#5253](https://github.com/manaflow-ai/cmux/pull/5253))
- Fix the diff viewer showing a raw CLI error and beeping when there is no diff ([#5252](https://github.com/manaflow-ai/cmux/pull/5252))
- Fix sidebar drag-and-drop frame collection with the lazy (virtualized) sidebar ([#5325](https://github.com/manaflow-ai/cmux/pull/5325))
- Lazy-load file explorer roots to speed up opening the file tree ([#5342](https://github.com/manaflow-ai/cmux/pull/5342))
- Fix Claude workflow resume transcript resolution ([#5242](https://github.com/manaflow-ai/cmux/pull/5242)) -- thanks @azooz2003-bit!
- Fix opening the remote SSH file browser ([#5241](https://github.com/manaflow-ai/cmux/pull/5241)) -- thanks @azooz2003-bit!
- Fix custom-sidebar extension discovery for tagged builds ([#5267](https://github.com/manaflow-ai/cmux/pull/5267)) -- thanks @azooz2003-bit!
- Fix Sparkle update packaging and Claude hook transcript scaling ([#5202](https://github.com/manaflow-ai/cmux/pull/5202))

### Thanks to 8 contributors!

- [@austinywang](https://github.com/austinywang)
- [@azooz2003-bit](https://github.com/azooz2003-bit)
- [@CharlesWiltgen](https://github.com/CharlesWiltgen)
- [@HamptonMakes](https://github.com/HamptonMakes)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@MaxiAschenbrenner](https://github.com/MaxiAschenbrenner)
- [@pstanton237](https://github.com/pstanton237)
- [@taonetm7](https://github.com/taonetm7)

## [0.64.12] - 2026-06-02

### Added
- Configurable keyboard shortcut to open the diff viewer, editable in Settings ([#5178](https://github.com/manaflow-ai/cmux/pull/5178))
- Font size and zoom controls in the Markdown viewer ([#5163](https://github.com/manaflow-ai/cmux/pull/5163))

### Changed
- Gate the Feed behind Beta Features (mirroring Dock), off by default ([#5174](https://github.com/manaflow-ai/cmux/pull/5174))
- Improve the terminal text context menu ([#5135](https://github.com/manaflow-ai/cmux/pull/5135)) -- thanks @azooz2003-bit!
- Rank visible title matches above hidden metadata in the workspace switcher ([#5148](https://github.com/manaflow-ai/cmux/pull/5148))
- Build the release app with the macOS 26 SDK ([#5042](https://github.com/manaflow-ai/cmux/pull/5042))

### Fixed
- Fix Starship and other custom prompts going static in bash by composing the prompt bootstrap with the user's existing `PROMPT_COMMAND` ([#5187](https://github.com/manaflow-ai/cmux/pull/5187)) -- thanks @xzjncu for the report!
- Report remote PTY allocation failures loudly so `cmux ssh` no longer fails silently when remote PTY attach fails ([#5186](https://github.com/manaflow-ai/cmux/pull/5186)) -- thanks @windyslow for the report!
- Fix a main-thread hang from focus-surface broadcast re-entrancy triggered by custom shortcuts ([#5108](https://github.com/manaflow-ai/cmux/pull/5108)) -- thanks @wzh4464 for the report!
- Restore the right-click sidebar view switcher and built-in views (Default Workspaces, Project Worktrees, and others) ([#5182](https://github.com/manaflow-ai/cmux/pull/5182))
- Strip terminal-color OSC sequences from restored scrollback so old sessions no longer keep a previous theme's colors (white-on-white after a theme change) ([#5175](https://github.com/manaflow-ai/cmux/pull/5175))
- Fix the browser Web Inspector reopening by itself after manual close and navigation ([#5180](https://github.com/manaflow-ai/cmux/pull/5180))
- Honor the Settings rebinding of Global Search by parsing package object-form `cmux.json` shortcut bindings ([#5143](https://github.com/manaflow-ai/cmux/pull/5143))
- Fix Claude fork and resume failing when the session had changed directories ([#5154](https://github.com/manaflow-ai/cmux/pull/5154))
- Fix titlebar shortcut-hint pills clipped at the bottom on macOS 26.5 ([#5145](https://github.com/manaflow-ai/cmux/pull/5145))
- Fall back to the default sidebar when extensions are disabled ([#5127](https://github.com/manaflow-ai/cmux/pull/5127)) -- thanks @azooz2003-bit!
- Stabilize the git metadata FSEvents watcher to stop an event storm ([#5131](https://github.com/manaflow-ai/cmux/pull/5131)) -- thanks @azooz2003-bit! and @randybias for the report!
- Avoid E2BIG when the SSH startup script exceeds `MAX_ARG_STRLEN` ([#5133](https://github.com/manaflow-ai/cmux/pull/5133)) -- thanks @lauzierj!

### Thanks to 8 contributors!

- [@austinywang](https://github.com/austinywang)
- [@azooz2003-bit](https://github.com/azooz2003-bit)
- [@lauzierj](https://github.com/lauzierj)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@randybias](https://github.com/randybias)
- [@windyslow](https://github.com/windyslow)
- [@wzh4464](https://github.com/wzh4464)
- [@xzjncu](https://github.com/xzjncu)

## [0.64.11] - 2026-06-01

### Added
- Workspace groups: select sidebar workspaces and press ⌘⇧G to group them under a collapsible header, with an anchor workspace, drag-to-group, in-group reorder, per-group color and icon, unread badges on the header, and a Delete Group action that closes all members ([#4815](https://github.com/manaflow-ai/cmux/pull/4815))
- `cmux workspace-group` CLI namespace to create, remove, set-color, set-icon, move, and focus groups, with new-workspace placement configurable per group and via `cmux.json` ([#5018](https://github.com/manaflow-ai/cmux/pull/5018))
- Focus history and Recently Closed history: navigate back and forward through recently focused workspaces and windows from the titlebar, and reopen recently closed surfaces from a searchable history pane ([#4160](https://github.com/manaflow-ai/cmux/pull/4160))
- Agent Hibernation pauses idle agent sessions and restores them on demand to cut background resource use ([#4165](https://github.com/manaflow-ai/cmux/pull/4165))
- Detachable SSH PTY daemon keeps remote sessions alive across reconnects so SSH workspaces survive a dropped connection ([#4807](https://github.com/manaflow-ai/cmux/pull/4807))
- Configurable sidebar workspace font size, plus a workspace tab bar font size control capped at 14pt ([#4798](https://github.com/manaflow-ai/cmux/pull/4798))
- Browser tab audio mute toggle in the tab right-click menu, kept in sync with WebKit playback state ([#4911](https://github.com/manaflow-ai/cmux/pull/4911))
- Fork Conversation action in the tab right-click menu, with configurable fork destinations ([#4888](https://github.com/manaflow-ai/cmux/pull/4888), [#4986](https://github.com/manaflow-ai/cmux/pull/4986) -- thanks @lawrence703!)
- Xcode-style project visualizer pane ([#4996](https://github.com/manaflow-ai/cmux/pull/4996))
- `cmux diff` command opens a CodeView diff viewer, with large git diffs streamed into the viewer before full render ([#4451](https://github.com/manaflow-ai/cmux/pull/4451), [#5016](https://github.com/manaflow-ai/cmux/pull/5016))
- Send Ctrl-F to Terminal passthrough action to force-stop Claude Code agents ([#5011](https://github.com/manaflow-ai/cmux/pull/5011))
- Native Kiro CLI hook integration with notifications, task manager attribution, and session restore ([#4831](https://github.com/manaflow-ai/cmux/pull/4831))
- Default terminal registration so the system terminal preference resolves to cmux ([#4935](https://github.com/manaflow-ai/cmux/pull/4935))
- Configurable browser search providers ([#4849](https://github.com/manaflow-ai/cmux/pull/4849))
- Terminal textbox input with beta TextBox defaults settings ([#4333](https://github.com/manaflow-ai/cmux/pull/4333), [#4773](https://github.com/manaflow-ai/cmux/pull/4773))
- Viewport-aware workspace path display truncates sidebar paths to fit the available width ([#3730](https://github.com/manaflow-ai/cmux/pull/3730)) -- thanks @gonzaloserrano!
- Wrap long workspace titles in the sidebar instead of truncating ([#4848](https://github.com/manaflow-ai/cmux/pull/4848))
- Open cmd-clicked Markdown paths in the Markdown viewer ([#4864](https://github.com/manaflow-ai/cmux/pull/4864))
- Beta Features toggle gates the in-progress extension sidebar UI ([#5092](https://github.com/manaflow-ai/cmux/pull/5092))

### Changed
- Notifications popover redesigned: bigger, minimal layout with swipe-to-dismiss ([#4778](https://github.com/manaflow-ai/cmux/pull/4778))
- Use Hermes hook payloads for richer agent notifications ([#4851](https://github.com/manaflow-ai/cmux/pull/4851))
- Settings is now a top-level peer window instead of a floating child window ([#5081](https://github.com/manaflow-ai/cmux/pull/5081))
- Launch restored agent sessions through their saved startup commands ([#4777](https://github.com/manaflow-ai/cmux/pull/4777))
- Reduce browser WebView input latency ([#4863](https://github.com/manaflow-ai/cmux/pull/4863))
- Make the workspace sidebar lazy with `@Observable` drag state and batch sidebar actions for faster reorders on large sidebars ([#4736](https://github.com/manaflow-ai/cmux/pull/4736), [#4865](https://github.com/manaflow-ai/cmux/pull/4865))
- Make session index backfill linear so large session histories load faster ([#4868](https://github.com/manaflow-ai/cmux/pull/4868))
- Resolve TypeScript `.ts` files as text previews instead of routing them through QuickLook media ([#4924](https://github.com/manaflow-ai/cmux/pull/4924))
- Forward CLI subcommands from the GUI binary to the bundled CLI ([#4679](https://github.com/manaflow-ai/cmux/pull/4679)) -- thanks @tiffanysun1!

### Fixed
- Fix File Preview hang when drag-selecting large files ([#4962](https://github.com/manaflow-ai/cmux/pull/4962))
- Fix the File Preview Open With menu ([#4932](https://github.com/manaflow-ai/cmux/pull/4932))
- Stop stale closed-browser snapshots from reappearing in unrelated workspaces ([#4961](https://github.com/manaflow-ai/cmux/pull/4961))
- Fix zsh hook errors when the job table is saturated ([#4959](https://github.com/manaflow-ai/cmux/pull/4959))
- Fix bash job notification spam ([#4934](https://github.com/manaflow-ai/cmux/pull/4934))
- Fix Claude hooks-disabled environment passthrough ([#4418](https://github.com/manaflow-ai/cmux/pull/4418))
- Fix `NSFileHandle` process pipe read crashes ([#4800](https://github.com/manaflow-ai/cmux/pull/4800))
- Fix cmux terminal environment injection ([#4728](https://github.com/manaflow-ai/cmux/pull/4728))
- Recognize Eternal Terminal for remote file drops ([#4712](https://github.com/manaflow-ai/cmux/pull/4712))
- Fix Vault resume for non-ASCII paths ([#4683](https://github.com/manaflow-ai/cmux/pull/4683))
- Fix Markdown files with trailing punctuation being detected as URLs ([#4594](https://github.com/manaflow-ai/cmux/pull/4594)) -- thanks @jasonko!
- Fix the Reload Configuration menu action ([#4534](https://github.com/manaflow-ai/cmux/pull/4534))
- Fix OMO tmux compatibility session ids ([#4468](https://github.com/manaflow-ai/cmux/pull/4468))
- Fix equalize split span weighting so 3+ pane rows distribute evenly ([#4787](https://github.com/manaflow-ai/cmux/pull/4787))
- Fix matched sidebar terminal background ([#4780](https://github.com/manaflow-ai/cmux/pull/4780))
- Fix restore-previous-launch crash and preserve current work on restore ([#4982](https://github.com/manaflow-ai/cmux/pull/4982))
- Fix agent resume when the saved cwd was deleted ([#4859](https://github.com/manaflow-ai/cmux/pull/4859))
- Fix hidden Settings window burning CPU during Codex output ([#4661](https://github.com/manaflow-ai/cmux/pull/4661))
- Fix embedded Ghostty split theme resolution so split panes inherit the active theme ([#4795](https://github.com/manaflow-ai/cmux/pull/4795))
- Fix titlebar controls intercepting window drags and right-sidebar button clicks ([#5005](https://github.com/manaflow-ai/cmux/pull/5005), [#5102](https://github.com/manaflow-ai/cmux/pull/5102))
- Fix split zoom not clearing when the maximized tab is closed ([#5076](https://github.com/manaflow-ai/cmux/pull/5076))
- Fix spurious "Terminal needs approval" prompts from the Hermes pre-tool-call hook ([#5010](https://github.com/manaflow-ai/cmux/pull/5010))
- Fix Hermes session restore so a per-turn session-end is treated as a turn boundary, not a teardown ([#5009](https://github.com/manaflow-ai/cmux/pull/5009))
- Fix the JSONC comment skipper for CRLF line endings ([#4869](https://github.com/manaflow-ai/cmux/pull/4869))
- Fix Bonsplit tab indicator drift ([#4873](https://github.com/manaflow-ai/cmux/pull/4873))
- Open bare relative path arguments externally without requiring socket access ([#4812](https://github.com/manaflow-ai/cmux/pull/4812))
- Keep Cmd-Tab app switching off the session snapshot path ([#4613](https://github.com/manaflow-ai/cmux/pull/4613))
- Restore the sidebar minimum width and keep the titlebar stable at minimum width ([#5062](https://github.com/manaflow-ai/cmux/pull/5062), [#5089](https://github.com/manaflow-ai/cmux/pull/5089))

### Removed
- Remove History from the right sidebar ([#4785](https://github.com/manaflow-ai/cmux/pull/4785))
- Remove the terminal scrollbar workspace menu ([#5072](https://github.com/manaflow-ai/cmux/pull/5072))
- Stop bundling example sidebars in the app ([#4662](https://github.com/manaflow-ai/cmux/pull/4662))

### Thanks to 7 contributors!

- [@austinywang](https://github.com/austinywang)
- [@azooz2003-bit](https://github.com/azooz2003-bit)
- [@gonzaloserrano](https://github.com/gonzaloserrano)
- [@jasonko](https://github.com/jasonko)
- [@lawrence703](https://github.com/lawrence703)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@tiffanysun1](https://github.com/tiffanysun1)

## [0.64.10] - 2026-05-23

### Added
- Copy on Select setting copies the active terminal selection to the clipboard as soon as the mouse is released ([#4011](https://github.com/manaflow-ai/cmux/pull/4011)) -- thanks @kallioaleksi for the report!
- CmuxExtensionKit sidebar prototypes showcase the upcoming extension API for custom workspace sidebars ([#4309](https://github.com/manaflow-ai/cmux/pull/4309))
- Ghostty Settings command palette action opens the embedded Ghostty configuration directly ([#4654](https://github.com/manaflow-ai/cmux/pull/4654))
- Warn before, or hide, the tab close button to prevent stray accidental closes ([#4632](https://github.com/manaflow-ai/cmux/pull/4632))
- Skip the quit-confirm dialog on DEV builds and honor `app.confirmQuit` on stable/nightly ([db267718](https://github.com/manaflow-ai/cmux/commit/db26771847df84b44f585d352d1b3bd709cb9715))
- Keep Codex notifications after interrupted turns so the badge survives a ctrl-c mid-stream ([#4583](https://github.com/manaflow-ai/cmux/pull/4583))
- Move resume command approvals into `cmux.json` so per-repo configuration can preapprove agent resume invocations ([#4538](https://github.com/manaflow-ai/cmux/pull/4538))
- `cmux reorder-workspaces` accepts batch input, supports `--dry-run`, and emits reorder events ([#4507](https://github.com/manaflow-ai/cmux/pull/4507))

### Changed
- Move the browser loading spinner onto Core Animation so it stays smooth during heavy rendering ([#4600](https://github.com/manaflow-ai/cmux/pull/4600))
- Harden remote websocket PTY sessions against connection churn ([#4323](https://github.com/manaflow-ai/cmux/pull/4323))

### Fixed
- Fix the TaskManager snapshot-boundary violation that caused the 0.64.8 memory leak by keeping pane store references out of the lazy list subtree ([#4555](https://github.com/manaflow-ai/cmux/pull/4555))
- Fix the `runProcess` pipe teardown crash hit when a process exits during stdout drain ([#4568](https://github.com/manaflow-ai/cmux/pull/4568))
- Fix key repeat rendering lag in the terminal under sustained input ([#3986](https://github.com/manaflow-ai/cmux/pull/3986))
- Fix asymmetric equalize splits so a 3+ pane row distributes evenly even when one pane started larger ([#4381](https://github.com/manaflow-ai/cmux/pull/4381))
- Fix `cmux.json` split ratios so persisted ratios apply to restored splits ([#3980](https://github.com/manaflow-ai/cmux/pull/3980))
- Fix browser URL bar stealing focus on tab switch ([#4623](https://github.com/manaflow-ai/cmux/pull/4623))
- Forward Cmd+Up / Cmd+Down to the browser pane so Google Docs and other web apps can jump to top/bottom ([#4637](https://github.com/manaflow-ai/cmux/pull/4637))
- Fix close shortcuts targeting the original window when the user has moved focus to a different one ([#4615](https://github.com/manaflow-ai/cmux/pull/4615))
- Fix Ghostty split theme appearance resolution so a freshly split pane inherits the active theme ([#4567](https://github.com/manaflow-ai/cmux/pull/4567))
- Fix theme picker chrome preview sync so the swatch matches the applied chrome ([#4652](https://github.com/manaflow-ai/cmux/pull/4652))
- Fix sidebar edge fade background so the gradient blends with the active surface ([#4610](https://github.com/manaflow-ai/cmux/pull/4610))
- Fix markdown remote SVG image loading inside the markdown viewer ([#4533](https://github.com/manaflow-ai/cmux/pull/4533))
- Fix restored panel unread sidebar badges so badge state survives session restore ([6f1ecc9f](https://github.com/manaflow-ai/cmux/commit/6f1ecc9fbfdbe2a3e1bb29e3ec1c018459629e59))
- Prevent DEV builds from stealing the stable CLI socket when both run side-by-side ([5ab642a3](https://github.com/manaflow-ai/cmux/commit/5ab642a3e9f8878f76e8d525a8d0ccc8c359a69b))

### Thanks to 3 contributors!

- [@austinywang](https://github.com/austinywang)
- [@kallioaleksi](https://github.com/kallioaleksi)
- [@lawrencecchen](https://github.com/lawrencecchen)

## [0.64.9] - 2026-05-21

### Fixed
- Stop unbounded Git repository search past filesystem root so non-Git workspaces no longer grow RSS from ~450MB to 8GB and trigger the OOM killer ([#4557](https://github.com/manaflow-ai/cmux/pull/4557)) -- thanks @Luciferxie for the report!
- Restore the Browser Memory Saver default to on (discards hidden browser webview renderers after the discard delay) to mitigate the 0.64.8 memory regression ([#4545](https://github.com/manaflow-ai/cmux/pull/4545)) -- thanks @Luciferxie for the report!

### Thanks to 3 contributors!

- [@austinywang](https://github.com/austinywang)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@Luciferxie](https://github.com/Luciferxie)

## [0.64.8] - 2026-05-21

### Added
- Antigravity CLI integration with hook notifications, task manager attribution, and session restore ([bd4a31c0](https://github.com/manaflow-ai/cmux/commit/bd4a31c000fc6552e5041abe87e121fcee9162ce))
- Native Grok Vault resume support ([5708d67b](https://github.com/manaflow-ai/cmux/commit/5708d67bcdf11f76ff582217575b36facdd91705))
- `--window` routing for window-scoped CLI commands (workspace, pane, surface, SSH, VM, notifications, tree, top) ([#4211](https://github.com/manaflow-ai/cmux/pull/4211))
- Browser screenshot clipboard actions ([#4479](https://github.com/manaflow-ai/cmux/pull/4479))
- Attribute notifications to their source panel ([20691adb](https://github.com/manaflow-ai/cmux/commit/20691adb467c5989312ccce2974a9325c76d987d))

### Changed
- Keep browser webviews alive by default, reverting the 0.64.7 discard-by-default behavior ([#4388](https://github.com/manaflow-ai/cmux/pull/4388))
- Align titlebar controls with macOS traffic lights ([#4471](https://github.com/manaflow-ai/cmux/pull/4471))
- Localize Antigravity hook strings and running status ([861d43a9](https://github.com/manaflow-ai/cmux/commit/861d43a99d574a1a0f21c2805b38ed35a28de587), [b5a4d6dc](https://github.com/manaflow-ai/cmux/commit/b5a4d6dcfeaa967f2c793d1870bd494ea3290a4b))

### Fixed
- Prevent minimal-mode pane tabs from moving the window when dragged ([e7941740](https://github.com/manaflow-ai/cmux/commit/e79417400654f71f4a8a26f59d5abc316366307d))
- Fix Option dead-key accent composition so Option+n then a commits "ã" ([#4382](https://github.com/manaflow-ai/cmux/pull/4382)) -- thanks @moskoweb for the report!
- Route keyboard/menu equalize_splits through v2ProportionalEqualize so 3+ panes split evenly ([#4400](https://github.com/manaflow-ai/cmux/pull/4400)) -- thanks @mvanhorn!
- Fix Quick Look preview deactivation crash ([#4459](https://github.com/manaflow-ai/cmux/pull/4459))
- Fix QuickLook crash after proxy icon split close ([#4460](https://github.com/manaflow-ai/cmux/pull/4460))
- Fix git index.lock polling in sidebar metadata watcher ([#2797](https://github.com/manaflow-ai/cmux/pull/2797))
- Fix theme override path for channel builds (Nightly/Staging no longer retheme Release) ([#4484](https://github.com/manaflow-ai/cmux/pull/4484))
- Fix minimal-mode sidebar titlebar icon alignment ([#4481](https://github.com/manaflow-ai/cmux/pull/4481))
- Fix notification Settings open path ([#4456](https://github.com/manaflow-ai/cmux/pull/4456))
- Suppress nested agent hook notifications ([#4334](https://github.com/manaflow-ai/cmux/pull/4334))
- Fix Antigravity presentation and resume ([0f67df81](https://github.com/manaflow-ai/cmux/commit/0f67df81566d677194e469c060f2a9367db02f7b))
- Fix Antigravity Vault resume indexing ([9fa5d1d8](https://github.com/manaflow-ai/cmux/commit/9fa5d1d8724d4b65bf886d86cc7bb9e9c295a026))
- Fix Antigravity fallback session build ([80fe38d6](https://github.com/manaflow-ai/cmux/commit/80fe38d6d0b3252b8f2f3c27cd78c0ca0a183016))
- Fix Antigravity conversation sanitizer width ([8bd285a9](https://github.com/manaflow-ai/cmux/commit/8bd285a94798dd49791995b699c3c2267ae06b6a))
- Fix Grok agent-scoped Vault filtering ([12ae177f](https://github.com/manaflow-ai/cmux/commit/12ae177f19caf91389770488c8aa2d0c2a3717c1))
- Fix Grok Vault titles and icon ([84373476](https://github.com/manaflow-ai/cmux/commit/843734760f019873c68e40657e48f4c740f24867))
- Deduplicate Grok Vault sessions ([9f66dffd](https://github.com/manaflow-ai/cmux/commit/9f66dffd2c352b4bd4d817aa3fdca5b04f5edb96))
- Honor shell Grok homes in Vault, including custom hook state directories ([be8c37c4](https://github.com/manaflow-ai/cmux/commit/be8c37c4f7ca82b4acd6226a22c34f6c1bbc6414), [f95b25b9](https://github.com/manaflow-ai/cmux/commit/f95b25b996b679bf02b4db2e6b24a7e97f15e274))
- Restore compact pane tab width ([f0370709](https://github.com/manaflow-ai/cmux/commit/f0370709a008e5165457f9cfc9ad41e75ebc942c))
- Fix session search ripgrep cancellation crash ([fa623368](https://github.com/manaflow-ai/cmux/commit/fa62336863148202fdefe679f2665b5801b1443c))
- Preserve right sidebar remembered mode ([aac80054](https://github.com/manaflow-ai/cmux/commit/aac800543a098f026091ab38e0bdf78e8beba5ff))
- Persist restored pane notifications and resync restored notification badges ([e4856922](https://github.com/manaflow-ai/cmux/commit/e4856922b07f96f9d5065fc2a46da346dabd52a2), [9ffdb45a](https://github.com/manaflow-ai/cmux/commit/9ffdb45a54e2c80832e2c471c1d10db06233b474))
- Preserve workspace cwd metadata for registered agents ([9b1e186d](https://github.com/manaflow-ai/cmux/commit/9b1e186d2ea7ef67e7c624b5e011289462a56eac))
- Preserve transparent terminal hosting ([1ca56296](https://github.com/manaflow-ai/cmux/commit/1ca56296d6c47acbcb6edddb47e89bd159097e2e))
- Keep browser URL tied to committed navigation and harden provisional navigation state ([40863609](https://github.com/manaflow-ai/cmux/commit/4086360910a9f4d40312f0536fcb03cb662c4ea7), [e240c302](https://github.com/manaflow-ai/cmux/commit/e240c302a10d43dc8bbf7ff17700af514166316e))
- Fix sidebar overlay contrast scheme and keep sidebar chrome readable across themes ([452745b6](https://github.com/manaflow-ai/cmux/commit/452745b65753953fed9d66cbb26878d6f755315b), [4223df74](https://github.com/manaflow-ai/cmux/commit/4223df74efe9bf0292c0b1e420950fdcb40c4e12))
- Synchronize theme contrast on reload and align terminal scheme with live theme ([228f3abd](https://github.com/manaflow-ai/cmux/commit/228f3abdd9d1c8fb93f640c5c202e6d2c0dcd13a), [b6d34706](https://github.com/manaflow-ai/cmux/commit/b6d34706683f6f4bc5aec8a4054939c6465a854b))
- Reload themes through the cmux socket so theme changes propagate to running instances ([1be9d26c](https://github.com/manaflow-ai/cmux/commit/1be9d26c3d79c92eff85fd8693973b5d893cd29b))
- Foreground and reload after interactive theme picker ([b0f58e47](https://github.com/manaflow-ai/cmux/commit/b0f58e4761a6bce30b6a6c1abc3916134e16b234), [8a4e57cf](https://github.com/manaflow-ai/cmux/commit/8a4e57cf7db118faaa9a6e0409b4c63afde36d57))
- Ignore inherited socket context from other cmux bundles ([b361e9a2](https://github.com/manaflow-ai/cmux/commit/b361e9a2fc04902864dda8197d82000d3330d3bb))
- Preserve numbered shortcut stale-menu routing and remapped close defaults ([d198a962](https://github.com/manaflow-ai/cmux/commit/d198a96266990062d01a6d968158e64d773bd6a2), [f2b257fb](https://github.com/manaflow-ai/cmux/commit/f2b257fb452b59dc674da4cb91d9ea6e97538c88))
- Clear restored unread on workspace resume and defer dismissal to focused panel ([b24cf548](https://github.com/manaflow-ai/cmux/commit/b24cf5484f26ef14cd1b90813c695607aad3b684), [f594d5a8](https://github.com/manaflow-ai/cmux/commit/f594d5a808dcf84a9c7492a03bf074071df85877))
- Update Bonsplit minimal tab drag hit testing and keep titlebar drag handle out of pane tabs ([36fc880f](https://github.com/manaflow-ai/cmux/commit/36fc880fdd8a070a545fbb1febb04405543c00b6), [735dde1d](https://github.com/manaflow-ai/cmux/commit/735dde1dccd7e1902d13f1e46c1f99eff674f5cd))
- Gate process termination until launch succeeds and handle deferred cancellation edge cases ([a14ca57c](https://github.com/manaflow-ai/cmux/commit/a14ca57cd0621b5f0c9371bd0ac71bbf60243b90), [227305d5](https://github.com/manaflow-ai/cmux/commit/227305d522d49905c02ea4941e9578d7d1a70c7c))
- Deduplicate shell wrapper installer ([a21a21c5](https://github.com/manaflow-ai/cmux/commit/a21a21c55fc26ebf59a5dcff29d30b6f71933ea2))

### Thanks to 4 contributors!

- [@austinywang](https://github.com/austinywang)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@moskoweb](https://github.com/moskoweb)
- [@mvanhorn](https://github.com/mvanhorn)

## [0.64.7] - 2026-05-19

### Added
- Grok Build CLI integration with notifications, task manager, and session restore ([#4225](https://github.com/manaflow-ai/cmux/pull/4225))
- Surface resume bindings ([#4237](https://github.com/manaflow-ai/cmux/pull/4237))
- Allow tab header double-click to zoom panes ([#3892](https://github.com/manaflow-ai/cmux/pull/3892)) -- thanks @Litee for the report!
- Open crash diagnostics from notifications ([#4296](https://github.com/manaflow-ai/cmux/pull/4296))
- Toggle Unread shortcut ([#4231](https://github.com/manaflow-ai/cmux/pull/4231))
- Command palette toggle for file opening ([#4208](https://github.com/manaflow-ai/cmux/pull/4208))
- Agent conversation fork commands ([#4198](https://github.com/manaflow-ai/cmux/pull/4198))
- Let terminal tabs move into existing workspaces ([#3890](https://github.com/manaflow-ai/cmux/pull/3890))
- Browser: hidden webview discard settings ([#4245](https://github.com/manaflow-ai/cmux/pull/4245)) -- thanks @lidge-jun!
- Browser: expose webview lifecycle state in `top` ([#4243](https://github.com/manaflow-ai/cmux/pull/4243)) -- thanks @lidge-jun!
- Show `cmux open` in CLI help ([#4206](https://github.com/manaflow-ai/cmux/pull/4206))

### Changed
- Preload CLI-created browser panes offscreen so they're ready when the workspace becomes visible ([#4345](https://github.com/manaflow-ai/cmux/pull/4345))
- Discard hidden browser webviews to reclaim memory ([#4244](https://github.com/manaflow-ai/cmux/pull/4244)) -- thanks @lidge-jun!
- Avoid idle background terminal surface priming ([#4184](https://github.com/manaflow-ai/cmux/pull/4184))
- Reduce Cloud VM create overhead ([#4202](https://github.com/manaflow-ai/cmux/pull/4202))
- Optimize command palette search ([#4043](https://github.com/manaflow-ai/cmux/pull/4043))
- Drop runtime-only flags from agent resume commands ([#4196](https://github.com/manaflow-ai/cmux/pull/4196)) -- thanks @dangaogit for the report!
- Open markdown files through the shared markdown viewer path ([#4285](https://github.com/manaflow-ai/cmux/pull/4285))
- Mark workspace unread when any tab inside it is marked unread ([#4169](https://github.com/manaflow-ai/cmux/pull/4169))
- Preserve unread indicators across session restore ([#4130](https://github.com/manaflow-ai/cmux/pull/4130))
- Reconcile provider-deleted Cloud VMs before applying active VM limits ([94c0b709](https://github.com/manaflow-ai/cmux/commit/94c0b709a2242771db1f16d2db9360e0d9cf8fee))
- Skip the approval prompt for CLI resume commands ([1b5bc76b](https://github.com/manaflow-ai/cmux/commit/1b5bc76ba81761811695555156051a2f88631811))

### Fixed
- Fix NIGHTLY update bundle icon metadata ([#4353](https://github.com/manaflow-ai/cmux/pull/4353))
- Fix ripgrep resolution for Nix installs ([#3946](https://github.com/manaflow-ai/cmux/pull/3946)) -- thanks @afterthought for the report!
- Prevent omo plugin warning infinite loop ([#3960](https://github.com/manaflow-ai/cmux/pull/3960)) -- thanks @liyue2008 for the report!
- Don't auto-resume an agent that already exited before the snapshot ([#4269](https://github.com/manaflow-ai/cmux/pull/4269)) -- thanks @wowpotato!
- Fix markdown viewer image rendering ([#4288](https://github.com/manaflow-ai/cmux/pull/4288))
- Fix task manager process accounting accuracy ([#4132](https://github.com/manaflow-ai/cmux/pull/4132))
- Fix browser omnibar IME candidate window for Japanese / Zhuyin ([#4268](https://github.com/manaflow-ai/cmux/pull/4268))
- Fix Cmd-hover bounds for spaced file paths ([#4291](https://github.com/manaflow-ai/cmux/pull/4291))
- Fix light theme foreground rendering when using conditional `dark:X,light:Y` themes ([#4278](https://github.com/manaflow-ai/cmux/pull/4278))
- Suppress browser editing shortcut replay ([#4186](https://github.com/manaflow-ai/cmux/pull/4186))
- Discover cmux user themes so the light theme palette applies as expected ([#3956](https://github.com/manaflow-ai/cmux/pull/3956)) -- thanks @abdullahnauman2 for the report!
- Fix Web Inspector blank restore and close crash ([#4182](https://github.com/manaflow-ai/cmux/pull/4182))
- Fix variant-aware CLI socket fallback ([#3543](https://github.com/manaflow-ai/cmux/pull/3543))
- Cmd-click reload now duplicates the browser tab (Chrome parity) ([#4284](https://github.com/manaflow-ai/cmux/pull/4284))
- Fix surface tab bar action button clipping on window resize ([#4121](https://github.com/manaflow-ai/cmux/pull/4121)) -- thanks @jmoses26 for the report!
- Fix Claude sidebar resume so it no longer overrides `CLAUDE_CONFIG_DIR` and triggers first-run prompts ([#4116](https://github.com/manaflow-ai/cmux/pull/4116)) -- thanks @hexalellogram for the report!
- Keep SSH pane close from killing sibling panes ([#3995](https://github.com/manaflow-ai/cmux/pull/3995)) -- thanks @kylejcaron for the report!
- Fix background workspace PTY startup for socket-created surfaces ([#3876](https://github.com/manaflow-ai/cmux/pull/3876)) -- thanks @hummer98 for the report!
- Preserve Codex plugin config during hook setup ([#4270](https://github.com/manaflow-ai/cmux/pull/4270))
- Fix browser deep-link popups (slack://, discord://, zoom://, etc.) ([#4226](https://github.com/manaflow-ai/cmux/pull/4226))
- Fix offscreen terminal helper PTY startup ([#4233](https://github.com/manaflow-ai/cmux/pull/4233))
- Fix Cmd-N routing from the browser omnibar ([#4038](https://github.com/manaflow-ai/cmux/pull/4038))
- Fix omnibar arrow key focus races ([#4183](https://github.com/manaflow-ai/cmux/pull/4183))
- Fix browser `window.showOpenFilePicker` support ([#4122](https://github.com/manaflow-ai/cmux/pull/4122)) -- thanks @ZhuYichuan for the report!
- Fix task manager attribution for launchd-parented helpers ([#4190](https://github.com/manaflow-ai/cmux/pull/4190))
- Fix background `new-workspace` commands ([#4137](https://github.com/manaflow-ai/cmux/pull/4137))
- Fix Slack composer Cmd+C in browser panes ([#4126](https://github.com/manaflow-ai/cmux/pull/4126))
- Fix permission notifications after auto-allow ([274128ec](https://github.com/manaflow-ai/cmux/commit/274128ec607500dcfc44cfe8495dae40eee87a68))
- Fix markdown and file preview panel session reuse ([838ad59f](https://github.com/manaflow-ai/cmux/commit/838ad59fed4e34ac913dc65ab9d7e391abaa708f))
- Fix nightly startup crash ([76ba2bfd](https://github.com/manaflow-ai/cmux/commit/76ba2bfde0ee6b7ef8773c2cb5a7897924457616))

### Thanks to 14 contributors!

- [@abdullahnauman2](https://github.com/abdullahnauman2)
- [@afterthought](https://github.com/afterthought)
- [@austinywang](https://github.com/austinywang)
- [@dangaogit](https://github.com/dangaogit)
- [@hexalellogram](https://github.com/hexalellogram)
- [@hummer98](https://github.com/hummer98)
- [@jmoses26](https://github.com/jmoses26)
- [@kylejcaron](https://github.com/kylejcaron)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@lidge-jun](https://github.com/lidge-jun)
- [@Litee](https://github.com/Litee)
- [@liyue2008](https://github.com/liyue2008)
- [@wowpotato](https://github.com/wowpotato)
- [@ZhuYichuan](https://github.com/ZhuYichuan)

## [0.64.6] - 2026-05-14

### Added
- Command palette toggles for boolean Settings rows, including iMessage Mode ([f85cc56a](https://github.com/manaflow-ai/cmux/commit/f85cc56ae99c235c61ea6ef091e88ccca6d4171d))

### Changed
- Improve Cloud VM error guidance with sign-in steps, unknown-flag suggestions, and usage examples ([#4094](https://github.com/manaflow-ai/cmux/pull/4094))
- Use transparent backgrounds for file preview panels so previews follow the active Ghostty theme opacity ([#4088](https://github.com/manaflow-ai/cmux/pull/4088))

### Fixed
- Fix `cmux ssh` dropping keystrokes after connecting — the backgrounded ssh inside the startup wrapper now inherits the wrapper's stdin so typing reaches the remote shell ([#4135](https://github.com/manaflow-ai/cmux/pull/4135)) -- thanks @kays0x for the fix, @kenfdev and @liudp1988 for the reports!
- Keep the selected workspace visible after sidebar reorders ([#4083](https://github.com/manaflow-ai/cmux/pull/4083))
- Fix Pi Vault icon and JSONL session titles ([#4120](https://github.com/manaflow-ai/cmux/pull/4120))

### Thanks to 5 contributors!

- [@austinywang](https://github.com/austinywang)
- [@kays0x](https://github.com/kays0x)
- [@kenfdev](https://github.com/kenfdev)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@liudp1988](https://github.com/liudp1988)

## [0.64.5] - 2026-05-13

### Added
- Codex Teams subagent panes that map `codex-teams` sessions into native cmux panes ([#4056](https://github.com/manaflow-ai/cmux/pull/4056))
- Task Manager column sorting and Program Totals that aggregate repeated processes by name ([#4066](https://github.com/manaflow-ai/cmux/pull/4066))
- Amp built-in restore and session plugin with hook installer ([be769af3](https://github.com/manaflow-ai/cmux/commit/be769af31d1adb5d9d00237a1f29b325a09c08f6)) -- thanks @comp615!
- Menubar global search across windows, workspaces, panes, and surfaces ([#3908](https://github.com/manaflow-ai/cmux/pull/3908))
- Open right sidebar tools as panes ([#4065](https://github.com/manaflow-ai/cmux/pull/4065))
- Workspace cwd inheritance setting ([#3921](https://github.com/manaflow-ai/cmux/pull/3921))
- Right-sidebar CLI command parity ([#3810](https://github.com/manaflow-ai/cmux/pull/3810))
- Bring notification CLI to panel parity with dismiss, mark-read, open, and jump-to-unread ([#3811](https://github.com/manaflow-ai/cmux/pull/3811))
- Open supported files in cmux on cmd-click ([#4041](https://github.com/manaflow-ai/cmux/pull/4041))
- Unread defer shortcut ([#4086](https://github.com/manaflow-ai/cmux/pull/4086))
- Pi agent icon ([#4057](https://github.com/manaflow-ai/cmux/pull/4057))
- iMessage workspace ordering and live message previews ([#4062](https://github.com/manaflow-ai/cmux/pull/4062))

### Changed
- Enable Feed by default ([#3854](https://github.com/manaflow-ai/cmux/pull/3854))
- Keep manually marked workspace and tab unread state sticky until you interact with the terminal, so navigation and focus don't clear it ([#4104](https://github.com/manaflow-ai/cmux/pull/4104))
- Route markdown paths from `cmux open` and `file.open` into markdown preview panels instead of generic file preview panels ([#4085](https://github.com/manaflow-ai/cmux/pull/4085))
- Rewritten Markdown viewer with a webview-based renderer ([#3664](https://github.com/manaflow-ai/cmux/pull/3664)) -- thanks @tobi!
- Auto-preserve Vertex/Bedrock auth env when launching the Claude wrapper inside cmux ([#3714](https://github.com/manaflow-ai/cmux/pull/3714)) -- thanks @psh4607!
- Approve installed Codex hooks during initial setup ([#4075](https://github.com/manaflow-ai/cmux/pull/4075))
- Hide sidebar descriptions in title-only mode ([#4040](https://github.com/manaflow-ai/cmux/pull/4040))
- Limit Cloud VMs by active provider state ([#4046](https://github.com/manaflow-ai/cmux/pull/4046))
- Save crash diagnostics under cmux state ([#4077](https://github.com/manaflow-ai/cmux/pull/4077))
- Reset Kitty keyboard mode at shell prompt boundaries ([#3870](https://github.com/manaflow-ai/cmux/pull/3870))
- Narrow IME candidate key suppression ([#3867](https://github.com/manaflow-ai/cmux/pull/3867))
- Keep Claude running after `/clear` ([#3631](https://github.com/manaflow-ai/cmux/pull/3631))
- Clarify in `cmux --help` that `reload-config` covers Ghostty config too ([#4060](https://github.com/manaflow-ai/cmux/pull/4060))

### Fixed
- Fix Korean 2-Set IME left/right terminal arrows ([#4095](https://github.com/manaflow-ai/cmux/pull/4095))
- Fix terminal portal resize lag ([#4102](https://github.com/manaflow-ai/cmux/pull/4102))
- Fix Settings search synonyms ([#4082](https://github.com/manaflow-ai/cmux/pull/4082))
- Fix sidebar unread badge after re-marking notifications ([#4084](https://github.com/manaflow-ai/cmux/pull/4084))
- Close browser panels when pages request window close ([#4070](https://github.com/manaflow-ai/cmux/pull/4070))
- Fix new-workspace caller window routing ([#4042](https://github.com/manaflow-ai/cmux/pull/4042))
- Prevent display-link crash from terminal portal layout reentry ([#3885](https://github.com/manaflow-ai/cmux/pull/3885))
- Fix shared WebView task manager attribution
- Fix stale SSH ControlPath cleanup before pane launch ([#3894](https://github.com/manaflow-ai/cmux/pull/3894))
- Prevent Metal renderer row rebuild crash ([#3916](https://github.com/manaflow-ai/cmux/pull/3916))
- Fix garbled Chinese paste text ([#3929](https://github.com/manaflow-ai/cmux/pull/3929))
- Fix cmux frontmost state without keyboard focus ([#3907](https://github.com/manaflow-ai/cmux/pull/3907))
- Reject unsupported durable Claude cron requests ([#3905](https://github.com/manaflow-ai/cmux/pull/3905))
- Use absolute remote path for cmuxd-remote scp upload ([#3880](https://github.com/manaflow-ai/cmux/pull/3880)) -- thanks @bcb225 for the report!
- Fix browser Return beep during sign-in ([#3843](https://github.com/manaflow-ai/cmux/pull/3843))
- Honor focusPaneOnFirstClick for minimal-mode chrome and workspace sidebar ([#3881](https://github.com/manaflow-ai/cmux/pull/3881)) -- thanks @rursache for the report!
- Preserve window position across sleep/wake with multiple monitors ([#3882](https://github.com/manaflow-ai/cmux/pull/3882)) -- thanks @al3kaz for the report!
- Fix terminal TUI background seam ([#3903](https://github.com/manaflow-ai/cmux/pull/3903))
- Pass Claude subcommands through the cmux wrapper ([#3871](https://github.com/manaflow-ai/cmux/pull/3871)) -- thanks @abdelibrahim-hh for the report!
- Open bare `window.open(_blank)` without features as a tab instead of a popup ([#3245](https://github.com/manaflow-ai/cmux/pull/3245)) -- thanks @azu for the report!
- Clear sidebar freeze after color/reorder so workspace rows keep updating ([#3874](https://github.com/manaflow-ai/cmux/pull/3874)) -- thanks @michaellopez for the report!
- Keep update pill polling current after the first update ([#3833](https://github.com/manaflow-ai/cmux/pull/3833))
- Redraw cmux window on focus regain even when the cursor is over the sidebar resize handle ([#3879](https://github.com/manaflow-ai/cmux/pull/3879)) -- thanks @mikesmitty for the report!
- Fix Cloud VM SSH attach and baked tooling ([#3786](https://github.com/manaflow-ai/cmux/pull/3786))
- Fix multi-image terminal drops ([#3769](https://github.com/manaflow-ai/cmux/pull/3769))
- Cover right sidebar tool panel in search
- Skip unrestorable Claude startup sessions ([#4079](https://github.com/manaflow-ai/cmux/pull/4079))
- Fix repeated assistant iMessage completions
- Sanitize Claude Agent View passthrough env

### Thanks to 12 contributors!

- [@abdelibrahim-hh](https://github.com/abdelibrahim-hh)
- [@al3kaz](https://github.com/al3kaz)
- [@austinywang](https://github.com/austinywang)
- [@azu](https://github.com/azu)
- [@bcb225](https://github.com/bcb225)
- [@comp615](https://github.com/comp615)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@michaellopez](https://github.com/michaellopez)
- [@mikesmitty](https://github.com/mikesmitty)
- [@psh4607](https://github.com/psh4607)
- [@rursache](https://github.com/rursache)
- [@tobi](https://github.com/tobi)

## [0.64.4] - 2026-05-11

### Added
- Add `warnBeforeClosingTab` close-warning toggle to opt back into the close confirmation prompt ([#2808](https://github.com/manaflow-ai/cmux/pull/2808)) -- thanks @dandaka for the report!
- Add `cmux browser cookies import` CLI for bringing cookies into cmux browser panes ([#3770](https://github.com/manaflow-ai/cmux/pull/3770))
- Add guarded `cmux://ssh` deep links that prompt before launching SSH ([#3677](https://github.com/manaflow-ai/cmux/pull/3677))
- Restore Vault Pi agent sessions across relaunch ([#3582](https://github.com/manaflow-ai/cmux/pull/3582), [#3636](https://github.com/manaflow-ai/cmux/pull/3636)) -- thanks @garizs for the report!
- Add Hermes Agent hook support ([#3585](https://github.com/manaflow-ai/cmux/pull/3585))
- Per-agent toggles for hiding Claude, Codex, OpenCode, Gemini, and Rovo Dev session restore ([#3616](https://github.com/manaflow-ai/cmux/pull/3616))
- Add Insert Path and Insert Relative Path context menu items in the file explorer ([#3620](https://github.com/manaflow-ai/cmux/pull/3620))
- Restore SSH workspace descriptors on relaunch ([#3576](https://github.com/manaflow-ai/cmux/pull/3576))
- Follow SSH workspaces in the Files sidebar so the remote root replaces the local macOS path ([#3721](https://github.com/manaflow-ai/cmux/pull/3721)) -- thanks @Lots-ninety-nine for the report!
- Add Welcome sidebar toggle shortcuts ([#3748](https://github.com/manaflow-ai/cmux/pull/3748))

### Changed
- File drop routing now defaults to text with Shift used as the split override.
- Allow HTTP localhost subdomains in browser panes ([#3764](https://github.com/manaflow-ai/cmux/pull/3764))
- Make browser find shortcuts respect remaps ([#3728](https://github.com/manaflow-ai/cmux/pull/3728))
- Make Close Tab remaps own browser popup close ([#3830](https://github.com/manaflow-ai/cmux/pull/3830))
- Alias top-level auth commands so `cmux signin` and `cmux signout` work without the `auth` prefix.

### Fixed
- Fix stale terminal foreground after theme switch leaving white-on-white text in running sessions ([#3852](https://github.com/manaflow-ai/cmux/pull/3852))
- Fix managed defaults replay overriding user changes after every `cmux.json` reload ([#3847](https://github.com/manaflow-ai/cmux/pull/3847))
- Preserve the Claude wrapper dev channel resume flag ([#3752](https://github.com/manaflow-ai/cmux/pull/3752)) -- thanks @Clean-Cole!
- Fix SSH browser loopback fetches reaching backends on second forwarded ports ([#3820](https://github.com/manaflow-ai/cmux/pull/3820))
- Fix modified Backspace deleting more than one character when an omnibar inline completion is showing ([#3842](https://github.com/manaflow-ai/cmux/pull/3842))
- Close Web Inspector before browser host teardown to prevent a UAF crash on pane close ([#3835](https://github.com/manaflow-ai/cmux/pull/3835))
- Fix Files sidebar find result aggregation ([#3818](https://github.com/manaflow-ai/cmux/pull/3818))
- Fix Escape dismissing the command palette ([#3823](https://github.com/manaflow-ai/cmux/pull/3823))
- Resume Claude, Codex, and OpenCode sessions from the session's original cwd.
- Fix Close Other Tabs targeting all tabs in the pane right-click menu ([#3628](https://github.com/manaflow-ai/cmux/pull/3628)) -- thanks @flatsponge for the report!
- Clear surface notifications during pane teardown so workspace badges don't stay stuck ([#3744](https://github.com/manaflow-ai/cmux/pull/3744))
- Fix folder proxy icon drag ([#3804](https://github.com/manaflow-ai/cmux/pull/3804)) -- thanks @lederniermagicien!
- Fix right sidebar shortcut defaults ([#3784](https://github.com/manaflow-ai/cmux/pull/3784))
- Fix right sidebar titlebar double-click ([#3750](https://github.com/manaflow-ai/cmux/pull/3750))
- Fix right sidebar Find typing lag ([#3739](https://github.com/manaflow-ai/cmux/pull/3739))
- Route SSH image drops through the terminal text path.
- Fix terminal top-row click routing ([#3720](https://github.com/manaflow-ai/cmux/pull/3720))
- Fix Mark Workspace as Unread enablement ([#3727](https://github.com/manaflow-ai/cmux/pull/3727)) -- thanks @mfn for the report!
- Fix Cmd-W to close Task Manager and auxiliary windows.
- Fix command palette arrow keys and no-match flash.
- Restore Zhuyin IME candidate marked-text handling ([#3574](https://github.com/manaflow-ai/cmux/pull/3574)) -- thanks @yuanganai for the report!
- Fix Task Manager CPU sampling ([#3588](https://github.com/manaflow-ai/cmux/pull/3588))
- Fix Cmd+N window size after the last window closes ([#3611](https://github.com/manaflow-ai/cmux/pull/3611)) -- thanks @bigtruth for the report!
- Fix Match Terminal Background sidebar toggle snapping back on ([#3635](https://github.com/manaflow-ai/cmux/pull/3635))
- Count cmux app RSS in Task Manager totals ([#3587](https://github.com/manaflow-ai/cmux/pull/3587))
- Keep Settings layered above the main window ([#3612](https://github.com/manaflow-ai/cmux/pull/3612))
- Forward Left/Right arrow keys to the browser surface ([#3663](https://github.com/manaflow-ai/cmux/pull/3663)) -- thanks @kimdane0115 for the report!
- Fix Rovo Dev transcript previews ([#3666](https://github.com/manaflow-ai/cmux/pull/3666))

### Thanks to 12 contributors!

- [@austinywang](https://github.com/austinywang)
- [@bigtruth](https://github.com/bigtruth)
- [@Clean-Cole](https://github.com/Clean-Cole)
- [@dandaka](https://github.com/dandaka)
- [@flatsponge](https://github.com/flatsponge)
- [@garizs](https://github.com/garizs)
- [@kimdane0115](https://github.com/kimdane0115)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@lederniermagicien](https://github.com/lederniermagicien)
- [@Lots-ninety-nine](https://github.com/Lots-ninety-nine)
- [@mfn](https://github.com/mfn)
- [@yuanganai](https://github.com/yuanganai)

## [0.64.3] - 2026-05-05

### Added
- Added Show in Finder to the workspace sidebar right-click menu.
- `cmux config` CLI with `cmux config doctor` for validating `cmux.json` without a socket, plus `cmux config path`, `cmux config docs`, and `cmux config reload` aliases ([#3454](https://github.com/manaflow-ai/cmux/pull/3454))

### Fixed
- Fix launch crash from off-main-thread CoreAnimation transactions when reapplying managed settings ([#3598](https://github.com/manaflow-ai/cmux/pull/3598))
- Fix file preview drag-and-drop so Finder and sidebar drops route into the hovered pane and tab bar drops insert as preview tabs ([#3539](https://github.com/manaflow-ai/cmux/pull/3539))

### Thanks to 2 contributors!

- [@austinywang](https://github.com/austinywang)
- [@lawrencecchen](https://github.com/lawrencecchen)

## [0.64.2] - 2026-05-05

### Fixed
- Fix launch crash on v0.64.1 caused by the bundled CLI failing to load the Sentry framework ([#3565](https://github.com/manaflow-ai/cmux/pull/3565)) -- thanks @hyi1233 for the report!
- Keep SSH sessions alive when closing a pane ([#3566](https://github.com/manaflow-ai/cmux/pull/3566)) -- thanks @kylejcaron for the report!
- Restore sidebar scroller visibility to reflect real overflow state ([#3570](https://github.com/manaflow-ai/cmux/pull/3570)) -- thanks @ibagur for the report!
- Fix Finder image drops into Claude Code terminals ([#3567](https://github.com/manaflow-ai/cmux/pull/3567)) -- thanks @streeyt for the report!
- Open links in the Markdown panel via an explicit OpenURLAction ([#3558](https://github.com/manaflow-ai/cmux/pull/3558)) -- thanks @psh4607!
- Prevent recursive lock crash on cmd-clicked Markdown viewer route and stop dropping fragment/query URLs ([#3559](https://github.com/manaflow-ai/cmux/pull/3559)) -- thanks @psh4607! Reported by @addisonlynch.
- Stop the Claude wrapper from auto-adding bypass-permissions flags and preserve user-provided `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` through terminal startup ([#3564](https://github.com/manaflow-ai/cmux/pull/3564))

### Thanks to 7 contributors!

- [@addisonlynch](https://github.com/addisonlynch)
- [@austinywang](https://github.com/austinywang)
- [@hyi1233](https://github.com/hyi1233)
- [@ibagur](https://github.com/ibagur)
- [@kylejcaron](https://github.com/kylejcaron)
- [@psh4607](https://github.com/psh4607)
- [@streeyt](https://github.com/streeyt)

## [0.64.1] - 2026-05-05

### Fixed
- Fix sidebar workspace close (×) button intermittently failing to appear on hover ([#3546](https://github.com/manaflow-ai/cmux/pull/3546))

### Thanks to 1 contributor!

- [@austinywang](https://github.com/austinywang)

## [0.64.0] - 2026-05-05

### Added
- Restore prior panes and resume Claude Code, Codex, OpenCode, Gemini, and Rovo Dev sessions across relaunch, including when you close the last window with the red X ([#2936](https://github.com/manaflow-ai/cmux/pull/2936), [#2978](https://github.com/manaflow-ai/cmux/pull/2978), [#3259](https://github.com/manaflow-ai/cmux/pull/3259), [#3419](https://github.com/manaflow-ai/cmux/pull/3419), [#3429](https://github.com/manaflow-ai/cmux/pull/3429), [#3487](https://github.com/manaflow-ai/cmux/pull/3487), [#3528](https://github.com/manaflow-ai/cmux/pull/3528), [#3530](https://github.com/manaflow-ai/cmux/pull/3530), [#3535](https://github.com/manaflow-ai/cmux/pull/3535))
- Passkey, WebAuthn, and FIDO2 support in browser panes ([#2660](https://github.com/manaflow-ai/cmux/pull/2660), [#2727](https://github.com/manaflow-ai/cmux/pull/2727), [#2905](https://github.com/manaflow-ai/cmux/pull/2905), [#2908](https://github.com/manaflow-ai/cmux/pull/2908))
- Task Manager window and `cmux top` CLI for window, workspace, pane, surface, and browser webview snapshots ([#3290](https://github.com/manaflow-ai/cmux/pull/3290), [#3471](https://github.com/manaflow-ai/cmux/pull/3471))
- Finder-like file explorer sidebar with SSH support ([#1963](https://github.com/manaflow-ai/cmux/pull/1963))
- File preview panels in the sidebar ([#3139](https://github.com/manaflow-ai/cmux/pull/3139))
- Menu bar only mode ([#3181](https://github.com/manaflow-ai/cmux/pull/3181))
- System-wide hotkey to show and hide cmux windows ([#2389](https://github.com/manaflow-ai/cmux/pull/2389))
- Cursor and Gemini CLI agent integrations with `setup-hooks` ([#2717](https://github.com/manaflow-ai/cmux/pull/2717))
- iMessage mode for agent prompts ([#3252](https://github.com/manaflow-ai/cmux/pull/3252))
- Settings sidebar shell and unified config utility window with cmux, Ghostty, and synced tabs ([#3024](https://github.com/manaflow-ai/cmux/pull/3024), [#3244](https://github.com/manaflow-ai/cmux/pull/3244), [#3400](https://github.com/manaflow-ai/cmux/pull/3400))
- Make `cmux.json` the canonical settings file with JSONC parsing and legacy `settings.json` fallback ([#3409](https://github.com/manaflow-ai/cmux/pull/3409), [#3424](https://github.com/manaflow-ai/cmux/pull/3424))
- Configurable `cmux.json` workspace and tab bar plus-button actions ([#3084](https://github.com/manaflow-ai/cmux/pull/3084), [#3348](https://github.com/manaflow-ai/cmux/pull/3348))
- Configurable surface tab bar font size ([#2645](https://github.com/manaflow-ai/cmux/pull/2645))
- Configurable workspace recoloring actions, default-bound to Ctrl+Option+0 through Ctrl+Option+9 ([#3327](https://github.com/manaflow-ai/cmux/pull/3327))
- Allow space as a bindable key, allow keyboard shortcuts to be unbound, and make reload and rename shortcuts context-aware ([#3333](https://github.com/manaflow-ai/cmux/pull/3333), [#3334](https://github.com/manaflow-ai/cmux/pull/3334), [#3468](https://github.com/manaflow-ai/cmux/pull/3468))
- Inline recorder messages explaining shortcut rejections and offering localized Reassign for conflicts ([#3035](https://github.com/manaflow-ai/cmux/pull/3035))
- Help menu with cmux docs nav, Skills, Agent Integrations submenu, and `skills.sh` install flow ([#3402](https://github.com/manaflow-ai/cmux/pull/3402))
- Find in directory shortcut ([#3208](https://github.com/manaflow-ai/cmux/pull/3208))
- Move tabs into new workspaces ([#3285](https://github.com/manaflow-ai/cmux/pull/3285))
- Hover tooltips on workspace and pane tabs ([#3329](https://github.com/manaflow-ai/cmux/pull/3329))
- Command palette ID copy actions and copy ID context menu actions ([#3183](https://github.com/manaflow-ai/cmux/pull/3183), [#3247](https://github.com/manaflow-ai/cmux/pull/3247))
- Command palette actions for right sidebar modes ([#3408](https://github.com/manaflow-ai/cmux/pull/3408))
- macOS clear glass background blur support ([#3313](https://github.com/manaflow-ai/cmux/pull/3313))
- Focus-neutral split-off layout command ([#3484](https://github.com/manaflow-ai/cmux/pull/3484))
- `--layout` parameter on `workspace.create` for programmatic split layouts ([#2916](https://github.com/manaflow-ai/cmux/pull/2916)) -- thanks @talldan!
- Korean (ko) localization ([#2885](https://github.com/manaflow-ai/cmux/pull/2885)) -- thanks @say8425!
- Opt-in setting to open Cmd-clicked Markdown files in the cmux Markdown viewer ([#2904](https://github.com/manaflow-ai/cmux/pull/2904)) -- thanks @SeongJaeSong!
- cmux browser disable switch ([#3256](https://github.com/manaflow-ai/cmux/pull/3256))
- Markdown and plain-text variants for docs pages plus `/llms.txt` index for agent consumption ([#3410](https://github.com/manaflow-ai/cmux/pull/3410))

### Changed
- Coalesce sidebar PR polling per-repo, drop checks fetch, and state-machine the probe queue to avoid GitHub rate limits ([#2585](https://github.com/manaflow-ai/cmux/pull/2585), [#2662](https://github.com/manaflow-ai/cmux/pull/2662))
- Speed up large terminal pastes by skipping eager HTML/RTF decoding when plain text is available ([#3000](https://github.com/manaflow-ai/cmux/pull/3000))
- Use workspace color for selected sidebar rows and the left rail ([#3038](https://github.com/manaflow-ai/cmux/pull/3038), [#3082](https://github.com/manaflow-ai/cmux/pull/3082), [#3310](https://github.com/manaflow-ai/cmux/pull/3310))
- Improve default light and dark theme fallback ([#3123](https://github.com/manaflow-ai/cmux/pull/3123))
- Sidebar PR clickability defaults to on, with visibility split from clickability as a separate setting ([#3273](https://github.com/manaflow-ai/cmux/pull/3273), [#3492](https://github.com/manaflow-ai/cmux/pull/3492))
- Make hook notifications non-blocking ([#3218](https://github.com/manaflow-ai/cmux/pull/3218))
- Clean up Claude session titles, render slash-command markup as readable titles, and skip meta caveats ([#3211](https://github.com/manaflow-ai/cmux/pull/3211))
- Apply sidebar background to right panel and consolidate sidebar settings ([#3103](https://github.com/manaflow-ai/cmux/pull/3103), [#3400](https://github.com/manaflow-ai/cmux/pull/3400))
- Improve settings search aliases with localized variants ([#3294](https://github.com/manaflow-ai/cmux/pull/3294), [#3296](https://github.com/manaflow-ai/cmux/pull/3296))
- Disable right sidebar horizontal scroll ([#3202](https://github.com/manaflow-ai/cmux/pull/3202))
- Optimize surface config reload ([#3480](https://github.com/manaflow-ai/cmux/pull/3480))
- Auto-hide terminal scroll bar with disable setting on TUI alt-screen ([#2678](https://github.com/manaflow-ai/cmux/pull/2678), [#2729](https://github.com/manaflow-ai/cmux/pull/2729))
- Show Codex TUI errors in the sidebar ([#3212](https://github.com/manaflow-ai/cmux/pull/3212))
- Keep Cmd-Shift-N windows on the source display ([#3214](https://github.com/manaflow-ai/cmux/pull/3214))
- Select find text on repeated Cmd+F ([#3314](https://github.com/manaflow-ai/cmux/pull/3314))
- Disable Claude OSC notifications in the cmux wrapper and gate Claude OSC suppression on integration setting ([#3418](https://github.com/manaflow-ai/cmux/pull/3418), [#3474](https://github.com/manaflow-ai/cmux/pull/3474))
- Namespace agent hook CLI commands ([#3298](https://github.com/manaflow-ai/cmux/pull/3298))

### Fixed
- Fix shell integration not injected when Ghostty `ZDOTDIR` overrides the wrapper ([#2778](https://github.com/manaflow-ai/cmux/pull/2778)) -- thanks @michaeljauk!
- Allow symlinked Ghostty config files ([#2813](https://github.com/manaflow-ai/cmux/pull/2813)) -- thanks @ivanrvpereira!
- Fix paste only pasting first character ([#2847](https://github.com/manaflow-ai/cmux/pull/2847)) -- thanks @dezren39!
- Prefer UTF-8 plain text in the pasteboard to avoid Mac OS Roman character loss ([#2877](https://github.com/manaflow-ai/cmux/pull/2877)) -- thanks @dasanworld!
- Fix blank split panes after portal reveal ([#2840](https://github.com/manaflow-ai/cmux/pull/2840)) -- thanks @jaynora2026!
- Fix workspace color picker context menu blinking ([#2566](https://github.com/manaflow-ai/cmux/pull/2566))
- Hide stale startup workspace portals during teardown ([#2658](https://github.com/manaflow-ai/cmux/pull/2658))
- Fix AX window polling stalls with app hierarchy caching ([#2986](https://github.com/manaflow-ai/cmux/pull/2986))
- Fix close confirmation bypass when spamming close ([#2989](https://github.com/manaflow-ai/cmux/pull/2989))
- Fix multi-workspace close confirmation modality ([#3153](https://github.com/manaflow-ai/cmux/pull/3153))
- Fix Cmd/Ctrl shortcut hint parity ([#2994](https://github.com/manaflow-ai/cmux/pull/2994))
- Cancel drag on Escape ([#3013](https://github.com/manaflow-ai/cmux/pull/3013))
- Pin regular-weight Japanese auto-fallback face ([#3015](https://github.com/manaflow-ai/cmux/pull/3015))
- Fix 100% CPU from ContentView publisher feedback loop ([#3028](https://github.com/manaflow-ai/cmux/pull/3028))
- Fix `DebugEventLog` `NSFileHandle` ObjC exception crash ([#3034](https://github.com/manaflow-ai/cmux/pull/3034))
- Fix main-thread blocking in workspace PR refresh ([#3036](https://github.com/manaflow-ai/cmux/pull/3036))
- Fix terminal blanking after OSC completion notifications ([#3048](https://github.com/manaflow-ai/cmux/pull/3048))
- Fix blank terminal after workspace selection ([#3012](https://github.com/manaflow-ai/cmux/pull/3012))
- Fix minimal-mode traffic-light inset, new-window Bonsplit tab bar, window routing, portal hit testing, drag pass-through, and pane tab rendering ([#3055](https://github.com/manaflow-ai/cmux/pull/3055), [#3150](https://github.com/manaflow-ai/cmux/pull/3150), [#3194](https://github.com/manaflow-ai/cmux/pull/3194), [#3399](https://github.com/manaflow-ai/cmux/pull/3399))
- Drop stale merged PRs from the sidebar badge selection ([#3063](https://github.com/manaflow-ai/cmux/pull/3063))
- Fix transparent titlebar backdrop matching and sidebar tint backdrop ownership ([#3179](https://github.com/manaflow-ai/cmux/pull/3179), [#3382](https://github.com/manaflow-ai/cmux/pull/3382))
- Fix feedback editor scrolling ([#3182](https://github.com/manaflow-ai/cmux/pull/3182))
- Fix bare `window.open(_blank)` routing in browser panes ([#3262](https://github.com/manaflow-ai/cmux/pull/3262))
- Fix non-ASCII Cmd+V paste when rich clipboard payloads are lossy ([#3268](https://github.com/manaflow-ai/cmux/pull/3268))
- Fix locale separators in sidebar identifiers ([#3269](https://github.com/manaflow-ai/cmux/pull/3269))
- Deduplicate numpad input across IME full-to-half-width transition ([#3292](https://github.com/manaflow-ai/cmux/pull/3292))
- Follow up equalize splits shortcut fixes ([#3309](https://github.com/manaflow-ai/cmux/pull/3309))
- Make find escape behavior consistent ([#3330](https://github.com/manaflow-ai/cmux/pull/3330))
- Fix unbound Cmd+Shift forwarding to terminal ([#3332](https://github.com/manaflow-ai/cmux/pull/3332))
- Make Ctrl+P command palette navigation remappable and Cmd+D new-tab shortcut rebindable ([#3335](https://github.com/manaflow-ai/cmux/pull/3335), [#3338](https://github.com/manaflow-ai/cmux/pull/3338), [#3398](https://github.com/manaflow-ai/cmux/pull/3398))
- Prevent shortcut recorder keys from navigating Settings ([#3377](https://github.com/manaflow-ai/cmux/pull/3377))
- Preserve context-separated shortcuts through recorder swaps ([#3489](https://github.com/manaflow-ai/cmux/pull/3489))
- Fix browser tab drag to new workspace, drops into sidebar workspaces, and terminal portal tab drop routing ([#3299](https://github.com/manaflow-ai/cmux/pull/3299), [#3381](https://github.com/manaflow-ai/cmux/pull/3381), [#3430](https://github.com/manaflow-ai/cmux/pull/3430))
- Fix Cmd+Shift+Enter pane zoom for browser panes ([#3520](https://github.com/manaflow-ai/cmux/pull/3520))
- Fix terminal focus after browser split ([#3460](https://github.com/manaflow-ai/cmux/pull/3460))
- Fix shortcut settings dispatch_once launch crash and settings-file launch crash paths ([#3455](https://github.com/manaflow-ai/cmux/pull/3455), [#3476](https://github.com/manaflow-ai/cmux/pull/3476))
- Fix editable shortcuts from `settings.json` ([#3462](https://github.com/manaflow-ai/cmux/pull/3462))
- Fix live theme picker application, launch theme before app appearance exists, and cmux theme picker Enter from search ([#3221](https://github.com/manaflow-ai/cmux/pull/3221), [#3378](https://github.com/manaflow-ai/cmux/pull/3378), [#3431](https://github.com/manaflow-ai/cmux/pull/3431), [#3479](https://github.com/manaflow-ai/cmux/pull/3479))
- Clamp Settings window away from display edge ([#3436](https://github.com/manaflow-ai/cmux/pull/3436))
- Fix SSH `LocalCommand` incompatibility with Fish shell ([#3506](https://github.com/manaflow-ai/cmux/pull/3506), [#3534](https://github.com/manaflow-ai/cmux/pull/3534))
- Fix OMX HUD bottom pane placement ([#3516](https://github.com/manaflow-ai/cmux/pull/3516))
- Fix inherited Claude auth env in cmux terminals ([#3519](https://github.com/manaflow-ai/cmux/pull/3519))
- Fix config window to open active cmux Ghostty config ([#3525](https://github.com/manaflow-ai/cmux/pull/3525))
- Fix notification dismissal with stale app focus ([#3532](https://github.com/manaflow-ai/cmux/pull/3532))
- Persist app icon mode on the app bundle ([#2884](https://github.com/manaflow-ai/cmux/pull/2884))
- Fix appIcon=automatic crash on macOS Tahoe ([#2833](https://github.com/manaflow-ai/cmux/pull/2833))
- Fix terminal selection autoscroll past viewport edge ([#2725](https://github.com/manaflow-ai/cmux/pull/2725))
- Fix command-hold shortcut hints and prevent sidebar truncation ([#2767](https://github.com/manaflow-ai/cmux/pull/2767))
- Fix Raycast paste fallback regression ([#2768](https://github.com/manaflow-ai/cmux/pull/2768))
- Fix Cmd+Shift+V paste in browser pane ([#2779](https://github.com/manaflow-ai/cmux/pull/2779))
- Fix up/down arrow keys in browser surface ([#2780](https://github.com/manaflow-ai/cmux/pull/2780))
- Fix Cmd+click file path punctuation trimming ([#2831](https://github.com/manaflow-ai/cmux/pull/2831))
- Fix bilibili search popup opening detached window ([#2836](https://github.com/manaflow-ai/cmux/pull/2836))
- Fix macOS modifier desync causing idle terminal input corruption ([#2855](https://github.com/manaflow-ai/cmux/pull/2855))
- Fix scrollback-limit byte handling ([#2927](https://github.com/manaflow-ai/cmux/pull/2927))
- Fix LinkedIn external-link redirect handoff in browser pane ([#2930](https://github.com/manaflow-ai/cmux/pull/2930))
- Fix OpenCode bracketed paste fallback in terminal ([#2971](https://github.com/manaflow-ai/cmux/pull/2971))
- Fix startup hang from repeated file drop overlay install ([#2972](https://github.com/manaflow-ai/cmux/pull/2972))
- Fix `cmux.json` named workspace colors ([#3149](https://github.com/manaflow-ai/cmux/pull/3149))
- Keep selected workspace visible in the sidebar ([#3152](https://github.com/manaflow-ai/cmux/pull/3152))
- Hide portals for unmounted workspaces ([#3155](https://github.com/manaflow-ai/cmux/pull/3155))
- Fix Bonsplit tab bar height and selected tab separator ([#3331](https://github.com/manaflow-ai/cmux/pull/3331), [#3351](https://github.com/manaflow-ai/cmux/pull/3351))
- Fix browser omnibar typing lag with many workspaces ([#3422](https://github.com/manaflow-ai/cmux/pull/3422))
- Fix nightly codesigning for nested bundles, Sparkle executables, and dock tile plugin ([#2676](https://github.com/manaflow-ai/cmux/pull/2676), [#2677](https://github.com/manaflow-ai/cmux/pull/2677), [#2679](https://github.com/manaflow-ai/cmux/pull/2679), [#2680](https://github.com/manaflow-ai/cmux/pull/2680))

### Thanks to 10 contributors!

- [@austinywang](https://github.com/austinywang)
- [@dasanworld](https://github.com/dasanworld)
- [@dezren39](https://github.com/dezren39)
- [@ivanrvpereira](https://github.com/ivanrvpereira)
- [@jaynora2026](https://github.com/jaynora2026)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@michaeljauk](https://github.com/michaeljauk)
- [@say8425](https://github.com/say8425)
- [@SeongJaeSong](https://github.com/SeongJaeSong)
- [@talldan](https://github.com/talldan)

## [0.63.2] - 2026-04-06

### Added
- Support chorded keyboard shortcuts ([#2528](https://github.com/manaflow-ai/cmux/pull/2528))
- Detect listening ports for remote SSH workspaces ([#2398](https://github.com/manaflow-ai/cmux/pull/2398))
- Editable workspace descriptions ([#2475](https://github.com/manaflow-ai/cmux/pull/2475))
- Claude Binary Path setting ([#2514](https://github.com/manaflow-ai/cmux/pull/2514))
- `cmux omx` and `cmux omc` agent integrations ([#2619](https://github.com/manaflow-ai/cmux/pull/2619))
- "Open Folder in VS Code (Inline)" menu item and command palette entry ([#2409](https://github.com/manaflow-ai/cmux/pull/2409))
- New Window entry in the Dock menu ([#2340](https://github.com/manaflow-ai/cmux/pull/2340))
- Reset-terminal workaround in the terminal menu ([#2349](https://github.com/manaflow-ai/cmux/pull/2349))
- React Grab inject button in the browser toolbar ([#2373](https://github.com/manaflow-ai/cmux/pull/2373))
- Hover background on split action buttons ([#2271](https://github.com/manaflow-ai/cmux/pull/2271))
- Cmd-click fallback for bare filenames in `ls` output ([#2294](https://github.com/manaflow-ai/cmux/pull/2294))
- Localized tab context menu and alert strings ([#2422](https://github.com/manaflow-ai/cmux/pull/2422))

### Changed
- Relicense cmux from AGPL-3.0 to GPL-3.0 ([#2364](https://github.com/manaflow-ai/cmux/pull/2364))
- Update bundled Ghostty fork to latest upstream ([#2379](https://github.com/manaflow-ai/cmux/pull/2379))
- Sidebar PR lookups are now event-driven to reduce GitHub API load ([#2453](https://github.com/manaflow-ai/cmux/pull/2453))
- Keep the latest sidebar notification until it is explicitly cleared ([#2623](https://github.com/manaflow-ai/cmux/pull/2623))
- Switch the nightly Sparkle appcast feed to R2 ([#2335](https://github.com/manaflow-ai/cmux/pull/2335), [#2363](https://github.com/manaflow-ai/cmux/pull/2363), [#2366](https://github.com/manaflow-ai/cmux/pull/2366))

### Fixed
- Fix terminals freezing when the first responder drifts off the focused surface ([#2505](https://github.com/manaflow-ai/cmux/pull/2505))
- Fix sidebar layout loop and CLI socket deadlocks ([#2601](https://github.com/manaflow-ai/cmux/pull/2601))
- Fix sidebar LazyVStack layout loop in the workspace list ([#2328](https://github.com/manaflow-ai/cmux/pull/2328))
- Fix focus reporting leak on pane creation ([#2511](https://github.com/manaflow-ai/cmux/pull/2511))
- Fix browser pane flicker during multi-split resize ([#2574](https://github.com/manaflow-ai/cmux/pull/2574))
- Fix browser panel resize flicker during split drag ([#2513](https://github.com/manaflow-ai/cmux/pull/2513))
- Fix browser pane hangs from redundant portal refreshes ([#2353](https://github.com/manaflow-ai/cmux/pull/2353))
- Fix browser pane dark-mode leak on light pages ([#2346](https://github.com/manaflow-ai/cmux/pull/2346))
- Fix DevTools pane breaking after workspace switch round-trips ([#2621](https://github.com/manaflow-ai/cmux/pull/2621))
- Fix sidebar background: add missing locale entries and portal resync on toggle ([#2622](https://github.com/manaflow-ai/cmux/pull/2622))
- Fix session restore suppression on relaunch ([#2469](https://github.com/manaflow-ai/cmux/pull/2469))
- Fix session restore terminal cursor focus race ([#2471](https://github.com/manaflow-ai/cmux/pull/2471))
- Fix terminal focus and surface recovery after layout changes ([#2354](https://github.com/manaflow-ai/cmux/pull/2354))
- Fix missing sidebar ports for agent-run dev servers ([#2562](https://github.com/manaflow-ai/cmux/pull/2562))
- Fix missing sidebar git branch metadata for workspaces ([#2563](https://github.com/manaflow-ai/cmux/pull/2563))
- Fix sidebar live refresh for branch and PR state ([#2331](https://github.com/manaflow-ai/cmux/pull/2331))
- Fix duplicate sidebar git metadata publishes ([#2405](https://github.com/manaflow-ai/cmux/pull/2405))
- Fix SSH password-auth bootstrap race ([#2564](https://github.com/manaflow-ai/cmux/pull/2564))
- Fix remote proxy notification spam with cooldown, backoff, and SSH keepalive ([#2330](https://github.com/manaflow-ai/cmux/pull/2330))
- Fix tmux-compat `split-window` surface resolution ([#2351](https://github.com/manaflow-ai/cmux/pull/2351))
- Fix `new-split` falling back to the focused surface when the target is stale ([#2518](https://github.com/manaflow-ai/cmux/pull/2518)) — thanks @anusheel!
- Fix CLI commands briefly stealing focus ([#2464](https://github.com/manaflow-ai/cmux/pull/2464))
- Fix paste from Raycast and other apps using alternate plain-text UTIs ([#2467](https://github.com/manaflow-ai/cmux/pull/2467))
- Fix stray `C` insertion from Speakly dictation ([#2413](https://github.com/manaflow-ai/cmux/pull/2413))
- Fix Korean IME jamo leak during composition ([#2529](https://github.com/manaflow-ai/cmux/pull/2529))
- Stop swallowing `/` and `?` on ABC-QWERTZ keyboard layouts ([#2447](https://github.com/manaflow-ai/cmux/pull/2447))
- Keep prompt colors when zsh switches local `TERM` to `xterm-256color` ([#2613](https://github.com/manaflow-ai/cmux/pull/2613))
- Ensure shell integrations always dispatch `claude` through the bundled wrapper ([#2465](https://github.com/manaflow-ai/cmux/pull/2465))
- Fix shell integration review regressions ([#2466](https://github.com/manaflow-ai/cmux/pull/2466))
- Fix React Grab Cmd+Shift+G terminal round-trip ([#2615](https://github.com/manaflow-ai/cmux/pull/2615))
- Suppress cmd-hover path highlighting while terminal selection is active ([#2579](https://github.com/manaflow-ai/cmux/pull/2579))
- Keep cmux browser Find shortcuts authoritative over page handlers ([#2356](https://github.com/manaflow-ai/cmux/pull/2356))
- Fix minimal-mode tab bar disappearing in fullscreen ([#2375](https://github.com/manaflow-ai/cmux/pull/2375))
- Fix transparent background flash during sidebar toggle ([#2378](https://github.com/manaflow-ai/cmux/pull/2378))
- Fix macOS 26 glass window gating ([#2468](https://github.com/manaflow-ai/cmux/pull/2468))
- Fix fullscreen new windows opening in the current Space ([#2345](https://github.com/manaflow-ai/cmux/pull/2345))
- Fix Dock persistence for manual app icons ([#2360](https://github.com/manaflow-ai/cmux/pull/2360))
- Fix update error details dialog overflow ([#2359](https://github.com/manaflow-ai/cmux/pull/2359))
- Fix Ctrl+K reaching the command palette text editor ([#2394](https://github.com/manaflow-ai/cmux/pull/2394))
- Keep Cmd+P stable during animated workspace title updates ([#2393](https://github.com/manaflow-ai/cmux/pull/2393))
- Fix Cmd+P workspace retention for the main CI workspace ([#2412](https://github.com/manaflow-ai/cmux/pull/2412))
- Coalesce portal sync to latest geometry to fix browser overlay drift ([#2214](https://github.com/manaflow-ai/cmux/pull/2214))
- Fix `claude_vm_node` OOM behavior and hook payload retention ([#2462](https://github.com/manaflow-ai/cmux/pull/2462))
- Fix GitHub star badge `k` formatting ([#2473](https://github.com/manaflow-ai/cmux/pull/2473))
- Keep GitHub stars badge stable across navigation ([#2476](https://github.com/manaflow-ai/cmux/pull/2476))
- Fix web header overlap ([#2452](https://github.com/manaflow-ai/cmux/pull/2452))

### Thanks to 3 contributors!

- [@austinywang](https://github.com/austinywang)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@anusheel](https://github.com/anusheel)

## [0.63.1] - 2026-03-28

### Fixed
- Fix crash on startup after upgrading from older versions due to stale window geometry data ([#2306](https://github.com/manaflow-ai/cmux/pull/2306))
- Fix re-entrant `displayIfNeeded` crash during layout follow-up from SwiftUI geometry changes ([#2305](https://github.com/manaflow-ai/cmux/pull/2305)) — thanks @KyleJamesWalker!
- Fix macOS compatibility with versioned geometry persistence to prevent future upgrade crashes ([#2308](https://github.com/manaflow-ai/cmux/pull/2308))

### Thanks to 2 contributors!

- [@austinywang](https://github.com/austinywang)
- [@KyleJamesWalker](https://github.com/KyleJamesWalker)

## [0.63.0] - 2026-03-28

### Added
- Browser profile import — cookies, history, and settings from Chrome, Firefox, Safari, and more ([#318](https://github.com/manaflow-ai/cmux/pull/318), [#1582](https://github.com/manaflow-ai/cmux/pull/1582), [#1593](https://github.com/manaflow-ai/cmux/pull/1593))
- Support `window.open()` popup windows in browser panes with shared OAuth context ([#1150](https://github.com/manaflow-ai/cmux/pull/1150), [#1600](https://github.com/manaflow-ai/cmux/pull/1600))
- Minimal mode — hide the titlebar for a distraction-free terminal ([#1479](https://github.com/manaflow-ai/cmux/pull/1479), [#2218](https://github.com/manaflow-ai/cmux/pull/2218))
- `cmux.json` custom commands — define project-specific actions launched from the command palette ([#2011](https://github.com/manaflow-ai/cmux/pull/2011), [#2122](https://github.com/manaflow-ai/cmux/pull/2122))
- `cmux omo` command for oh-my-openagent integration ([#2087](https://github.com/manaflow-ai/cmux/pull/2087), [#2230](https://github.com/manaflow-ai/cmux/pull/2230), [#2280](https://github.com/manaflow-ai/cmux/pull/2280))
- Codex CLI hooks integration for terminal notifications ([#2103](https://github.com/manaflow-ai/cmux/pull/2103))
- Customizable number shortcuts for workspace switching ([#1951](https://github.com/manaflow-ai/cmux/pull/1951))
- Customizable sidebar selection highlight color ([#1824](https://github.com/manaflow-ai/cmux/pull/1824))
- Match Terminal Background sidebar color setting ([#2293](https://github.com/manaflow-ai/cmux/pull/2293))
- Optional single-click focus for inactive split panes ([#1796](https://github.com/manaflow-ai/cmux/pull/1796))
- Support image drag-and-drop into SSH terminals ([#1838](https://github.com/manaflow-ai/cmux/pull/1838))
- Support dropping folders onto the dock icon to open as workspaces ([#1571](https://github.com/manaflow-ai/cmux/pull/1571))
- Support modifier+key combinations in `send-key` CLI — ctrl+enter, shift+tab, arrow keys, home/end/delete/pageup/pagedown ([#1994](https://github.com/manaflow-ai/cmux/pull/1994), [#1920](https://github.com/manaflow-ai/cmux/pull/1920))
- `--name` flag for `new-workspace` CLI command ([#2160](https://github.com/manaflow-ai/cmux/pull/2160))
- `--no-focus` flag for `cmux ssh` ([#2227](https://github.com/manaflow-ai/cmux/pull/2227))
- `--direction` flag for markdown open command ([#1763](https://github.com/manaflow-ai/cmux/pull/1763))
- Per-surface TTY exposed in `cmux tree` output ([#2040](https://github.com/manaflow-ai/cmux/pull/2040))
- `set-color` / `clear-color` workspace actions for tab color via CLI ([#1873](https://github.com/manaflow-ai/cmux/pull/1873), [#1833](https://github.com/manaflow-ai/cmux/pull/1833))
- IntelliJ IDEA added to command palette Open Directory targets ([#1860](https://github.com/manaflow-ai/cmux/pull/1860))
- Open a new terminal tab from empty tab bar double-click ([#1601](https://github.com/manaflow-ai/cmux/pull/1601))
- Double-click custom titlebar to zoom or minimize ([#2130](https://github.com/manaflow-ai/cmux/pull/2130))
- Confirm before closing pinned workspaces ([#1895](https://github.com/manaflow-ai/cmux/pull/1895))
- Show tab name in close tab confirmation dialog ([#1845](https://github.com/manaflow-ai/cmux/pull/1845))
- Sidebar listening ports are now clickable to open in browser ([#1844](https://github.com/manaflow-ai/cmux/pull/1844))
- Ukrainian (uk) localization ([#2226](https://github.com/manaflow-ai/cmux/pull/2226))
- Hidden CLI command for live terminal debugging ([#1599](https://github.com/manaflow-ai/cmux/pull/1599))
- `rc` and `remote-control` added to command passthrough ([#1539](https://github.com/manaflow-ai/cmux/pull/1539))
- Export `CMUX_SOCKET` alongside `CMUX_SOCKET_PATH` in terminal env ([#1991](https://github.com/manaflow-ai/cmux/pull/1991))
- Dual licensing — AGPL + commercial ([#2021](https://github.com/manaflow-ai/cmux/pull/2021))
- Universal binary (arm64 + x86_64) for stable releases ([#2287](https://github.com/manaflow-ai/cmux/pull/2287))
- Add claude-teams, omo, and __tmux-compat to Go relay CLI for SSH sessions ([#2238](https://github.com/manaflow-ai/cmux/pull/2238))
- Warn Before Quit enforced when Cmd+Q arrives via app switcher ([#2186](https://github.com/manaflow-ai/cmux/pull/2186))

### Changed
- Show update-available banner automatically on launch ([#1651](https://github.com/manaflow-ai/cmux/pull/1651), [#1543](https://github.com/manaflow-ai/cmux/pull/1543), [#1575](https://github.com/manaflow-ai/cmux/pull/1575))
- Restore Sparkle scheduled update checks ([#1597](https://github.com/manaflow-ai/cmux/pull/1597))
- New window inherits size from current window ([#2124](https://github.com/manaflow-ai/cmux/pull/2124))
- Restore last-surface close preference toggle ([#1679](https://github.com/manaflow-ai/cmux/pull/1679))
- Rename "Import From Browser" to "Import Browser Data" ([#1672](https://github.com/manaflow-ai/cmux/pull/1672))
- Make founders email selectable in feedback success view ([#1733](https://github.com/manaflow-ai/cmux/pull/1733))
- Include hardware details in feedback submissions ([#1726](https://github.com/manaflow-ai/cmux/pull/1726))
- Coalesce scrollbar updates during bulk output for improved performance ([#2116](https://github.com/manaflow-ai/cmux/pull/2116))
- Reduce shell integration prompt latency ([#2109](https://github.com/manaflow-ai/cmux/pull/2109))
- Skip quit confirmation for tagged DEV builds ([#2288](https://github.com/manaflow-ai/cmux/pull/2288))
- Use dedicated setting for sidebar port link browser preference ([#2219](https://github.com/manaflow-ai/cmux/pull/2219))
- Skip sidebar PR lookup on main/master branches ([#2110](https://github.com/manaflow-ai/cmux/pull/2110))
- Stabilize sidebar directory ordering when split focus changes ([#1798](https://github.com/manaflow-ai/cmux/pull/1798))
- Improve tmux notification attention routing ([#1898](https://github.com/manaflow-ai/cmux/pull/1898))

### Fixed
- Fix Cmd+N workspace creation crashes caused by stale snapshots, ARC hotpaths, and restore-time races ([#2204](https://github.com/manaflow-ai/cmux/pull/2204), [#2183](https://github.com/manaflow-ai/cmux/pull/2183), [#2181](https://github.com/manaflow-ai/cmux/pull/2181), [#2178](https://github.com/manaflow-ai/cmux/pull/2178), [#2176](https://github.com/manaflow-ai/cmux/pull/2176), [#2173](https://github.com/manaflow-ai/cmux/pull/2173), [#2133](https://github.com/manaflow-ai/cmux/pull/2133), [#2023](https://github.com/manaflow-ai/cmux/pull/2023), [#1985](https://github.com/manaflow-ai/cmux/pull/1985), [#1930](https://github.com/manaflow-ai/cmux/pull/1930))
- Fix ARC workspace inheritance crash and native Zig helper builds ([#2283](https://github.com/manaflow-ai/cmux/pull/2283))
- Fix `EXC_BAD_ACCESS` caused by over-releasing Ghostty font ([#1496](https://github.com/manaflow-ai/cmux/pull/1496))
- Fix terminal black screen on macOS 26.3.1 by dispatching Ghostty callbacks to main thread ([#1937](https://github.com/manaflow-ai/cmux/pull/1937))
- Fix blank terminal renders after workspace switches ([#1964](https://github.com/manaflow-ai/cmux/pull/1964))
- Fix stale terminal portal after restore churn ([#2025](https://github.com/manaflow-ai/cmux/pull/2025))
- Fix floating portal terminal after nightly update relaunch ([#1696](https://github.com/manaflow-ai/cmux/pull/1696))
- Fix terminal portal resync after restore-time bind ([#1973](https://github.com/manaflow-ai/cmux/pull/1973))
- Fix terminal find overlay crash and focus handoff ([#1487](https://github.com/manaflow-ai/cmux/pull/1487))
- Fix split transparency regression ([#1568](https://github.com/manaflow-ai/cmux/pull/1568))
- Apply `background-opacity` and `background-blur` to terminal rendering area ([#1858](https://github.com/manaflow-ai/cmux/pull/1858))
- Fix keyboard shortcuts not working with CJK input sources (Korean, Japanese, Russian) ([#1649](https://github.com/manaflow-ai/cmux/pull/1649), [#1913](https://github.com/manaflow-ai/cmux/pull/1913), [#2202](https://github.com/manaflow-ai/cmux/pull/2202))
- Skip CJK fallback font injection when font-family already covers glyphs ([#2241](https://github.com/manaflow-ai/cmux/pull/2241))
- Skip Korean from CJK font-codepoint-map auto-injection ([#1700](https://github.com/manaflow-ai/cmux/pull/1700))
- Fix Japanese IME confirmation Enter from executing command prematurely ([#2075](https://github.com/manaflow-ai/cmux/pull/2075), [#1671](https://github.com/manaflow-ai/cmux/pull/1671))
- Fix Korean IME Enter handling on composition path in browser panes ([#2108](https://github.com/manaflow-ai/cmux/pull/2108))
- Fix AZERTY Option+Delete word delete in Claude Code ([#1640](https://github.com/manaflow-ai/cmux/pull/1640))
- Fix Escape key not working in terminal panels (e.g., lazygit) ([#1957](https://github.com/manaflow-ai/cmux/pull/1957))
- Fix unbound Cmd+Shift+key combos being silently swallowed ([#1959](https://github.com/manaflow-ai/cmux/pull/1959))
- Fix Cmd+W closing terminal tabs instead of About/Licenses windows ([#1473](https://github.com/manaflow-ai/cmux/pull/1473))
- Fix Cmd+O opening Documents folder — handle in custom shortcut handler ([#2034](https://github.com/manaflow-ai/cmux/pull/2034))
- Consume Cmd+number shortcuts when workspace index is out of bounds ([#2033](https://github.com/manaflow-ai/cmux/pull/2033))
- Fix arrow key glyph matching in customizable shortcuts ([#1443](https://github.com/manaflow-ai/cmux/pull/1443))
- Fix cursor movement on double-click selection ([#1709](https://github.com/manaflow-ai/cmux/pull/1709))
- Fix doomscroll when reviewing scrollback ([#1616](https://github.com/manaflow-ai/cmux/pull/1616))
- Fix browser panes rendering blank after reopen ([#2141](https://github.com/manaflow-ai/cmux/pull/2141))
- Fix browser portal leaking to other tabs on Bonsplit tab switch ([#2000](https://github.com/manaflow-ai/cmux/pull/2000))
- Fix browser freeze after pane split ([#1852](https://github.com/manaflow-ai/cmux/pull/1852))
- Fix browser pane video fullscreen ([#1921](https://github.com/manaflow-ai/cmux/pull/1921))
- Fix browser image copy pasteboard data ([#1850](https://github.com/manaflow-ai/cmux/pull/1850))
- Fix browser pane file drops hanging on "Uploading" ([#1843](https://github.com/manaflow-ai/cmux/pull/1843))
- Fix browser back navigation history handoff ([#1897](https://github.com/manaflow-ai/cmux/pull/1897))
- Fix browser devtools X-close persistence ([#1627](https://github.com/manaflow-ai/cmux/pull/1627))
- Fix browser PR metadata deadlock and BrowserPanelView hot paths ([#1564](https://github.com/manaflow-ai/cmux/pull/1564))
- Fix Cloudflare/CAPTCHA verification failures in browser panel ([#1877](https://github.com/manaflow-ai/cmux/pull/1877))
- Fix Google sign-in infinite loading in browser pane ([#1493](https://github.com/manaflow-ai/cmux/pull/1493))
- Fix native value setter for React compatibility in browser panes ([#2059](https://github.com/manaflow-ai/cmux/pull/2059))
- Fix sidebar badges not refreshing on workspace state change ([#2046](https://github.com/manaflow-ai/cmux/pull/2046))
- Fix sidebar PR badge detection for workspace branches and restored workspaces ([#1896](https://github.com/manaflow-ai/cmux/pull/1896), [#1570](https://github.com/manaflow-ai/cmux/pull/1570), [#1636](https://github.com/manaflow-ai/cmux/pull/1636))
- Fix sidebar notification persisting after being read ([#1933](https://github.com/manaflow-ai/cmux/pull/1933))
- Fix premature workspace title truncation in sidebar ([#1859](https://github.com/manaflow-ai/cmux/pull/1859))
- Fix pinned workspace ordering — keep pinned workspaces above pin boundary ([#1503](https://github.com/manaflow-ai/cmux/pull/1503), [#1505](https://github.com/manaflow-ai/cmux/pull/1505))
- Fix command palette ordering for "check" query ([#1740](https://github.com/manaflow-ai/cmux/pull/1740))
- Fix command palette focus after terminal find ([#2089](https://github.com/manaflow-ai/cmux/pull/2089))
- Fix missing command palette open-in targets ([#1621](https://github.com/manaflow-ai/cmux/pull/1621))
- Fix all split panes appearing focused after layout restoration ([#2088](https://github.com/manaflow-ai/cmux/pull/2088))
- Fix panel resize stuttering when tiled with browser panels ([#1969](https://github.com/manaflow-ai/cmux/pull/1969))
- Fix splitter hitbox overlap and terminal scrollbar width resync ([#1950](https://github.com/manaflow-ai/cmux/pull/1950))
- Increase content side hit width to prevent accidental window resize ([#2018](https://github.com/manaflow-ai/cmux/pull/2018))
- Fix window position restore on relaunch ([#2129](https://github.com/manaflow-ai/cmux/pull/2129))
- Fix dock icon not auto-switching with system dark mode ([#1928](https://github.com/manaflow-ai/cmux/pull/1928), [#1510](https://github.com/manaflow-ai/cmux/pull/1510))
- Align titlebar icons with traffic-light buttons ([#1754](https://github.com/manaflow-ai/cmux/pull/1754))
- Fix focused notification sound playback ([#1855](https://github.com/manaflow-ai/cmux/pull/1855))
- Fix laggy terminal sync during sidebar drags ([#1598](https://github.com/manaflow-ai/cmux/pull/1598))
- Fix spinner hang after display resolution changes ([#1549](https://github.com/manaflow-ai/cmux/pull/1549))
- Fix workspace layout follow-up spin loop ([#1633](https://github.com/manaflow-ai/cmux/pull/1633))
- Fix Ghostty `resize_split` keybind support ([#1899](https://github.com/manaflow-ai/cmux/pull/1899))
- Fix update attempt refreshing pill without actually updating ([#2168](https://github.com/manaflow-ai/cmux/pull/2168), [#2142](https://github.com/manaflow-ai/cmux/pull/2142), [#2117](https://github.com/manaflow-ai/cmux/pull/2117))
- Fix SSH control master cleanup on remote teardown ([#2104](https://github.com/manaflow-ai/cmux/pull/2104))
- Fix SSH cleanup after moving the last remote surface ([#2123](https://github.com/manaflow-ai/cmux/pull/2123))
- Fix SSH image transfer cleanup and IPv6 followups ([#1907](https://github.com/manaflow-ai/cmux/pull/1907), [#1904](https://github.com/manaflow-ai/cmux/pull/1904))
- Fix SSH remote CLI wrapper and proxy follow-ups ([#1596](https://github.com/manaflow-ai/cmux/pull/1596))
- Fix nightly SSH remote daemon checksum mismatch ([#2225](https://github.com/manaflow-ai/cmux/pull/2225))
- Fix cmux ssh notify surface targeting ([#1799](https://github.com/manaflow-ai/cmux/pull/1799))
- Fix tmux compat store decoding, layout cleanup, and cross-workspace fallback ([#2207](https://github.com/manaflow-ai/cmux/pull/2207))
- Fix claude-teams pane anchoring with main-vertical layout ([#2119](https://github.com/manaflow-ai/cmux/pull/2119))
- Fix claude-hook stop teardown races ([#1954](https://github.com/manaflow-ai/cmux/pull/1954))
- Fix Claude Code hooks config to match actual schema ([#1388](https://github.com/manaflow-ai/cmux/pull/1388))
- Handle TabManager unavailable in SessionEnd/Start hooks ([#1735](https://github.com/manaflow-ai/cmux/pull/1735))
- Fix blocking sleep in preexec hook causing command lag ([#1444](https://github.com/manaflow-ai/cmux/pull/1444))
- Fix redundant focus events causing Powerlevel10k redraws ([#1579](https://github.com/manaflow-ai/cmux/pull/1579))
- Fix identical session autosave writes ([#1732](https://github.com/manaflow-ai/cmux/pull/1732))
- Fix locale page crashes under Google Translate ([#1956](https://github.com/manaflow-ai/cmux/pull/1956))
- Fix About Panel newline escaping ([#1298](https://github.com/manaflow-ai/cmux/pull/1298))
- Fix remote sidebar directory canonicalization to preserve live paths ([#1800](https://github.com/manaflow-ai/cmux/pull/1800))
- Fix AppleScript `count windows` returning 0 and `working directory` returning empty ([#1826](https://github.com/manaflow-ai/cmux/pull/1826))
- Fix PWD action routing to correct TabManager per tabId ([#2147](https://github.com/manaflow-ai/cmux/pull/2147))
- Fix socket returning wrong error when surface_id is provided but unresolvable ([#2150](https://github.com/manaflow-ai/cmux/pull/2150))
- Guard inherited terminal config against stale surfaces ([#2101](https://github.com/manaflow-ai/cmux/pull/2101))
- Suppress socat stdout in `_cmux_send` to prevent "OK" leak ([#1619](https://github.com/manaflow-ai/cmux/pull/1619))
- Add `-r` shorthand to skip session ID check in Claude wrapper ([#1992](https://github.com/manaflow-ai/cmux/pull/1992))
- Check git repo before running git commands to prevent TCC permission prompts ([#1677](https://github.com/manaflow-ai/cmux/pull/1677))
- Preserve explicit wheel scrollback against passive follow ([#1965](https://github.com/manaflow-ai/cmux/pull/1965))
- Fix terminal pane drag/drop handoff delay ([#1837](https://github.com/manaflow-ai/cmux/pull/1837))

### Removed
- Remove restricted web-browser entitlement ([#1727](https://github.com/manaflow-ai/cmux/pull/1727))

## [0.62.2] - 2026-03-14

### Added
- Configurable sidebar tint color with separate light/dark mode support via Settings and config file (`sidebar-background`, `sidebar-tint-opacity`) ([#1465](https://github.com/manaflow-ai/cmux/pull/1465))
- Cmd+P all-surfaces search option ([#1382](https://github.com/manaflow-ai/cmux/pull/1382))
- `cmux themes` command with bundled Ghostty themes ([#1334](https://github.com/manaflow-ai/cmux/pull/1334), [#1314](https://github.com/manaflow-ai/cmux/pull/1314))
- Sidebar can now shrink to smaller widths ([#1420](https://github.com/manaflow-ai/cmux/pull/1420))
- Menu bar visibility setting ([#1330](https://github.com/manaflow-ai/cmux/pull/1330))

### Changed
- CLI Sentry events are now tagged with the app release ([#1408](https://github.com/manaflow-ai/cmux/pull/1408))
- Stable socket listener now falls back to a user-scoped path, and repeated startup failures are throttled ([#1351](https://github.com/manaflow-ai/cmux/pull/1351), [#1415](https://github.com/manaflow-ai/cmux/pull/1415))

### Fixed
- Command palette command-mode shortcut, navigation, and omnibar backspace or arrow-key regressions ([#1417](https://github.com/manaflow-ai/cmux/pull/1417), [#1413](https://github.com/manaflow-ai/cmux/pull/1413))
- Stale Claude sidebar status from missing hooks, OSC suppression, and PID cleanup ([#1306](https://github.com/manaflow-ai/cmux/pull/1306))
- Split cwd inheritance when the shell cwd is stale ([#1403](https://github.com/manaflow-ai/cmux/pull/1403))
- Crashes when creating a new workspace and when inserting a workspace into an orphaned window context ([#1391](https://github.com/manaflow-ai/cmux/pull/1391), [#1380](https://github.com/manaflow-ai/cmux/pull/1380))
- Cmd+W close behavior and close-confirmation shell-state regressions ([#1395](https://github.com/manaflow-ai/cmux/pull/1395), [#1386](https://github.com/manaflow-ai/cmux/pull/1386))
- macOS dictation NSTextInputClient conformance and terminal image-paste fallbacks ([#1410](https://github.com/manaflow-ai/cmux/pull/1410), [#1305](https://github.com/manaflow-ai/cmux/pull/1305), [#1361](https://github.com/manaflow-ai/cmux/pull/1361), [#1358](https://github.com/manaflow-ai/cmux/pull/1358))
- VS Code command palette target resolution, Ghostty Pure prompt redraws, and internal drag regressions ([#1389](https://github.com/manaflow-ai/cmux/pull/1389), [#1363](https://github.com/manaflow-ai/cmux/pull/1363), [#1316](https://github.com/manaflow-ai/cmux/pull/1316), [#1379](https://github.com/manaflow-ai/cmux/pull/1379))

## [0.62.1] - 2026-03-13

### Added
- Cmd+T (New tab) shortcut on the welcome screen ([#1258](https://github.com/manaflow-ai/cmux/pull/1258))

### Fixed
- Cmd+backtick window cycling skipping windows
- Titlebar shortcut hint clipping ([#1259](https://github.com/manaflow-ai/cmux/pull/1259))
- Terminal portals desyncing after sidebar changes ([#1253](https://github.com/manaflow-ai/cmux/pull/1253))
- Background terminal focus retries reordering windows
- Pure-style multiline prompt redraws in Ghostty
- Return key not working on Cmd+Ctrl+W close confirmation ([#1279](https://github.com/manaflow-ai/cmux/pull/1279))
- Concurrent remote daemon RPC calls timing out ([#1281](https://github.com/manaflow-ai/cmux/pull/1281))

### Removed
- SSH remote port proxying (reverted, will return in a future release)

## [0.62.0] - 2026-03-12

### Added
- Markdown viewer panel with live file watching ([#883](https://github.com/manaflow-ai/cmux/pull/883))
- Find-in-page (Cmd+F) for browser panels ([#837](https://github.com/manaflow-ai/cmux/issues/837), [#875](https://github.com/manaflow-ai/cmux/pull/875))
- Keyboard copy mode for terminal scrollback with vi-style navigation ([#792](https://github.com/manaflow-ai/cmux/pull/792))
- Custom notification sounds with file picker support ([#839](https://github.com/manaflow-ai/cmux/pull/839), [#869](https://github.com/manaflow-ai/cmux/pull/869))
- Browser camera and microphone permission support ([#760](https://github.com/manaflow-ai/cmux/issues/760), [#913](https://github.com/manaflow-ai/cmux/pull/913))
- Language setting for per-app locale override ([#886](https://github.com/manaflow-ai/cmux/pull/886))
- Japanese localization ([#819](https://github.com/manaflow-ai/cmux/pull/819))
- 16 new languages added to localization ([#895](https://github.com/manaflow-ai/cmux/pull/895))
- Kagi as a search provider option ([#561](https://github.com/manaflow-ai/cmux/pull/561))
- Open Folder command (Cmd+O) ([#656](https://github.com/manaflow-ai/cmux/pull/656))
- Dark mode app icon for macOS Sequoia ([#702](https://github.com/manaflow-ai/cmux/pull/702))
- Close other pane tabs with confirmation ([#475](https://github.com/manaflow-ai/cmux/pull/475))
- Flash Focused Panel command palette action ([#638](https://github.com/manaflow-ai/cmux/pull/638))
- Zoom/maximize focused pane in splits ([#634](https://github.com/manaflow-ai/cmux/pull/634))
- `cmux tree` command for full CLI hierarchy view ([#592](https://github.com/manaflow-ai/cmux/pull/592))
- Install or uninstall the `cmux` CLI from the command palette ([#626](https://github.com/manaflow-ai/cmux/pull/626))
- Clipboard image paste in terminal with Cmd+V ([#562](https://github.com/manaflow-ai/cmux/pull/562), [#853](https://github.com/manaflow-ai/cmux/pull/853))
- Middle-click X11-style selection paste in terminal ([#369](https://github.com/manaflow-ai/cmux/pull/369))
- Honor Ghostty `background-opacity` across all cmux chrome ([#667](https://github.com/manaflow-ai/cmux/pull/667))
- Setting to hide Cmd-hold shortcut hints ([#765](https://github.com/manaflow-ai/cmux/pull/765))
- Focus-follows-mouse on terminal hover ([#519](https://github.com/manaflow-ai/cmux/pull/519))
- Sidebar help menu in the footer ([#958](https://github.com/manaflow-ai/cmux/pull/958))
- External URL bypass rules for the embedded browser ([#768](https://github.com/manaflow-ai/cmux/pull/768))
- Telemetry opt-out setting ([#610](https://github.com/manaflow-ai/cmux/pull/610))
- Browser automation docs page ([#622](https://github.com/manaflow-ai/cmux/pull/622))
- Vim mode indicator badge on terminal panes ([#1092](https://github.com/manaflow-ai/cmux/pull/1092))
- Sidebar workspace color in CLI sidebar_state output ([#1101](https://github.com/manaflow-ai/cmux/pull/1101))
- Prompt before closing window with Cmd+Ctrl+W ([#1219](https://github.com/manaflow-ai/cmux/pull/1219))
- Jump to Latest button in notifications popover ([#1167](https://github.com/manaflow-ai/cmux/pull/1167))
- Khmer localization ([#1198](https://github.com/manaflow-ai/cmux/pull/1198))
- cmux claude-teams launcher ([#1179](https://github.com/manaflow-ai/cmux/pull/1179))

### Changed
- Command palette search is now async and decoupled from typing for reduced lag
- Fuzzy matching improved with single-edit and omitted-character word matches
- Replaced keychain password storage with file-based storage ([#576](https://github.com/manaflow-ai/cmux/pull/576))
- Fullscreen shortcut changed to Cmd+Ctrl+F, and Cmd+Enter also toggles fullscreen ([#530](https://github.com/manaflow-ai/cmux/pull/530))
- Workspace rename shortcut Cmd+Shift+R now uses the command palette flow
- Renamed tab color to workspace color in user-facing strings ([#637](https://github.com/manaflow-ai/cmux/pull/637))
- Feedback recipient changed to `feedback@manaflow.com` ([#1007](https://github.com/manaflow-ai/cmux/pull/1007))
- Regenerated app icons from Icon Composer ([#1005](https://github.com/manaflow-ai/cmux/pull/1005))
- Moved update logs into the Debug menu ([#1008](https://github.com/manaflow-ai/cmux/pull/1008))
- Updated Ghostty to v1.3.0 ([#1142](https://github.com/manaflow-ai/cmux/pull/1142))
- Welcome screen colors adapted for light mode ([#1214](https://github.com/manaflow-ai/cmux/pull/1214))
- Notification sound picker width constrained ([#1168](https://github.com/manaflow-ai/cmux/pull/1168))

### Fixed
- Frozen blank launch from session restore race condition ([#399](https://github.com/manaflow-ai/cmux/issues/399), [#565](https://github.com/manaflow-ai/cmux/pull/565))
- Crash on launch from an exclusive access violation in drag-handle hit testing ([#490](https://github.com/manaflow-ai/cmux/issues/490))
- Use-after-free in `ghostty_surface_refresh` after sleep/wake ([#432](https://github.com/manaflow-ai/cmux/issues/432), [#619](https://github.com/manaflow-ai/cmux/pull/619))
- Startup SIGSEGV by pre-warming locale before `SentrySDK.start` ([#927](https://github.com/manaflow-ai/cmux/pull/927))
- IME issues: Shift+Space toggle inserting a space ([#641](https://github.com/manaflow-ai/cmux/issues/641), [#670](https://github.com/manaflow-ai/cmux/pull/670)), Ctrl fast path blocking IME events, browser address bar Japanese IME ([#789](https://github.com/manaflow-ai/cmux/issues/789), [#867](https://github.com/manaflow-ai/cmux/pull/867)), and Cmd shortcuts during IME composition
- CLI socket autodiscovery for tagged sockets ([#832](https://github.com/manaflow-ai/cmux/pull/832))
- Flaky CLI socket listener recovery ([#952](https://github.com/manaflow-ai/cmux/issues/952), [#954](https://github.com/manaflow-ai/cmux/pull/954))
- Side-docked dev tools resize ([#712](https://github.com/manaflow-ai/cmux/pull/712))
- Dvorak Cmd+C colliding with the notifications shortcut ([#762](https://github.com/manaflow-ai/cmux/pull/762))
- Terminal drag hover overlay flicker
- Titlebar controls clipped at the bottom edge ([#1016](https://github.com/manaflow-ai/cmux/pull/1016))
- Sidebar git branch recovery after sleep/wake and agent checkout ([#494](https://github.com/manaflow-ai/cmux/issues/494), [#671](https://github.com/manaflow-ai/cmux/pull/671), [#905](https://github.com/manaflow-ai/cmux/pull/905))
- Browser portal routing, uploads, and click focus regressions ([#908](https://github.com/manaflow-ai/cmux/pull/908), [#961](https://github.com/manaflow-ai/cmux/pull/961))
- Notification unread persistence on workspace focus
- Escape propagation when the command palette is visible ([#847](https://github.com/manaflow-ai/cmux/pull/847))
- Cmd+Shift+Enter pane zoom regression in browser focus ([#826](https://github.com/manaflow-ai/cmux/pull/826))
- Cross-window theme background after jump-to-unread ([#861](https://github.com/manaflow-ai/cmux/pull/861))
- `window.open()` and `target=_blank` not opening in a new tab ([#693](https://github.com/manaflow-ai/cmux/pull/693))
- Terminal wrap width for the overlay scrollbar ([#522](https://github.com/manaflow-ai/cmux/pull/522))
- Orphaned child processes when closing workspace tabs ([#889](https://github.com/manaflow-ai/cmux/pull/889))
- Cmd+F Escape passthrough into terminal ([#918](https://github.com/manaflow-ai/cmux/pull/918))
- Terminal link opens staying in the source workspace ([#912](https://github.com/manaflow-ai/cmux/pull/912))
- Ghost terminal surface rebind after close ([#808](https://github.com/manaflow-ai/cmux/pull/808))
- Cmd+plus zoom handling on non-US keyboard layouts ([#680](https://github.com/manaflow-ai/cmux/pull/680))
- Menubar icon invisible in light mode ([#741](https://github.com/manaflow-ai/cmux/pull/741))
- Various drag-handle crash fixes and reentrancy guards
- Background workspace git metadata refresh after external checkout
- Markdown panel text click focus ([#991](https://github.com/manaflow-ai/cmux/pull/991))
- Browser Cmd+F overlay clipping in portal mode ([#916](https://github.com/manaflow-ai/cmux/pull/916))
- Voice dictation text insertion ([#857](https://github.com/manaflow-ai/cmux/pull/857))
- Browser panel lifecycle after WebContent process termination ([#892](https://github.com/manaflow-ai/cmux/pull/892))
- Typing lag reduction by hiding invisible views from the accessibility tree ([#862](https://github.com/manaflow-ai/cmux/pull/862))
- CJK font fallback preventing decorative font rendering for CJK characters ([#1017](https://github.com/manaflow-ai/cmux/pull/1017))
- Inline VS Code serve-web token exposure via argv ([#1033](https://github.com/manaflow-ai/cmux/pull/1033))
- Browser pane portal anchor sizing ([#1094](https://github.com/manaflow-ai/cmux/pull/1094))
- Pinned workspace notification reordering ([#1116](https://github.com/manaflow-ai/cmux/pull/1116))
- cmux --version memory blowup ([#1121](https://github.com/manaflow-ai/cmux/pull/1121))
- Notification ring dismissal on direct terminal clicks ([#1126](https://github.com/manaflow-ai/cmux/pull/1126))
- Browser portal visibility when terminal tab is active ([#1130](https://github.com/manaflow-ai/cmux/pull/1130))
- Browser panes reloading when switching workspaces ([#1136](https://github.com/manaflow-ai/cmux/pull/1136))
- Sidebar PR badge detection ([#1139](https://github.com/manaflow-ai/cmux/pull/1139))
- Browser address bar disappearing during pane zoom ([#1145](https://github.com/manaflow-ai/cmux/pull/1145))
- Ghost terminal surface focus after split close ([#1148](https://github.com/manaflow-ai/cmux/pull/1148))
- Browser DevTools resize loop and layout stability ([#1170](https://github.com/manaflow-ai/cmux/pull/1170), [#1173](https://github.com/manaflow-ai/cmux/pull/1173), [#1189](https://github.com/manaflow-ai/cmux/pull/1189))
- Typing lag from sidebar re-evaluation and hitTest overhead ([#1204](https://github.com/manaflow-ai/cmux/issues/1204))
- Browser pane stale content after drag splits ([#1215](https://github.com/manaflow-ai/cmux/pull/1215))
- Terminal drop overlay misplacement during drag hover ([#1213](https://github.com/manaflow-ai/cmux/pull/1213))
- Hidden browser slot inspector focus crash ([#1211](https://github.com/manaflow-ai/cmux/pull/1211))
- Browser devtools hide fallback ([#1220](https://github.com/manaflow-ai/cmux/pull/1220))
- Browser portal refresh on geometry churn ([#1224](https://github.com/manaflow-ai/cmux/pull/1224))
- Browser tab switch triggering unnecessary reload ([#1228](https://github.com/manaflow-ai/cmux/pull/1228))
- Devtools side dock guard for attached devtools ([#1230](https://github.com/manaflow-ai/cmux/pull/1230))

### Thanks to 24 contributors!
- [@0xble](https://github.com/0xble)
- [@afxjzs](https://github.com/afxjzs)
- [@AI-per](https://github.com/AI-per)
- [@atani](https://github.com/atani)
- [@atmigtnca](https://github.com/atmigtnca)
- [@austinywang](https://github.com/austinywang)
- [@cheulyop](https://github.com/cheulyop)
- [@ConnorCallison](https://github.com/ConnorCallison)
- [@gonzaloserrano](https://github.com/gonzaloserrano)
- [@harukitosa](https://github.com/harukitosa)
- [@homanp](https://github.com/homanp)
- [@JLeeChan](https://github.com/JLeeChan)
- [@josemasri](https://github.com/josemasri)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@novarii](https://github.com/novarii)
- [@orkhanrz](https://github.com/orkhanrz)
- [@qianwan](https://github.com/qianwan)
- [@rjwittams](https://github.com/rjwittams)
- [@sminamot](https://github.com/sminamot)
- [@tmcarr](https://github.com/tmcarr)
- [@trydis](https://github.com/trydis)
- [@ukoasis](https://github.com/ukoasis)
- [@y-agatsuma](https://github.com/y-agatsuma)
- [@yasunogithub](https://github.com/yasunogithub)

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
