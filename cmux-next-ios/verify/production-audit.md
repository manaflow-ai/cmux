# cmux-next-ios production-readiness audit

Date: 2026-10-13. Audited at `feat-cnx-ios-audit` 7584b3b1e714 (iOS app,
`cmux-next-ios/rust`, `cmux-next-ios/backend`, verify docs) and `origin/feat-cnx-ios-machost`
e29f59c89cfc (Mac integration, bundled `cmux-mobile-host`). Read-only: nothing was
built or run. Every row was found by reading code or docs; the key rows were
re-checked by hand.

Prompt: "is there anything else you just winged?" Yes. The mock Chief and mock
terminal are now compiled out of Production (7584b3b1). What is still wrong:

- Production runs on dev infrastructure.
- Device trust is a bearer token.
- Phone-made tabs and attachments are fake.
- Several settings and status lines are decorative.
- Most "done" claims rest on mocks, a scripted agent, a stub TUI, or one shared NAT.

Path prefixes:

- `CK/` = `cmux-next-ios/CmuxMobileKit/Sources/`
- `mh:` = `origin/feat-cnx-ios-machost`
- `MH/` = `Packages/macOS/CmuxNext/Sources/` on that branch

Other paths are relative to `cmux-next-ios/`.

## Executive summary: blockers

1. **Prod on the dev Worker and dev DB.** The iOS Production config, the Mac app Release build and `run-host.sh` all use `cmux-mobile-api-dev.debussy.workers.dev`. The prod Worker was never deployed.
2. **Bearer-token device trust.** No device keypair, no install-key handshake and no Mac approval. A leaked Stack token can register a "phone", evict the real Mac, and `send`/`send-key` into live terminals.
3. **No unpair, revoke, device delete or account deletion.** The backend has no DELETE route at all. Account deletion is required by App Store 5.1.1(v).
4. **Chief is offline in production.** hostd serves only `echo`, `daemon`, `acpmux` and `file`, and `conversation-*` is not allowlisted. Chief was only ever verified on `ChiefMockBackend`.
5. **Phone permissions are deny-only.** Allow, and every question answer, are shown but always refused.
6. **Phone-made tabs are phone-only.** New Claude/Codex/Terminal/Browser tabs and Close never reach the Mac. They vanish on refresh, or stay on "Connecting…" forever.
7. **Terminal attachments are never uploaded.** A made-up `~/.mobile/uploads/<name>` path is typed into the shell and Return is pressed.
8. **Agent-chat Files attachments are silently dropped at send.**
9. **Compose-to-Chief can lose the first message** with no error.
10. **Sign in with Apple cannot work.** No `com.apple.developer.applesignin` entitlement exists in any config, yet the Apple button is first on Welcome.
11. **The "Require Face ID" toggle is saved but never enforced.**
12. **Notifications and Live Activities are promised in Setup and Settings but do not exist.** There is no APNs, ActivityKit or background refresh, and the toggles are never read.
13. **Paired Macs shows fabricated status:** "Online · X direct" and "Last seen 3h ago".
14. **The Release config ships with no API base.** A signed-in user gets an empty app. Release is the `xcodebuild archive` default.
15. **The app-supervised hostd and the signed/notarized release bundle have never run**, and nightly-next notarization is paused.

## Findings

Owners:

- **machost:** machost production-readiness
- **chieflive:** real Chief
- **termlive:** terminal input lane
- **fastconn:** connect and cached states
- **browserstream:** video and browser streaming

### Production config and backend

| Severity | Area | What's fake / missing / unverified | Evidence | What production needs | Owner |
| --- | --- | --- | --- | --- | --- |
| blocker | iOS config | Production `CMUX_MOBILE_API_BASE` is the dev Worker. `check-production-binary.sh` only checks for HTTPS, so it passes. | `project.yml:37-38` | A prod Worker URL. The binary check should reject `-dev`. | machost |
| blocker | Mac config | The Release Mac app always uses the dev Worker. The override is DEBUG only. | `mh:MH/CmuxNextMobileHost/IPhoneHostService+Wiring.swift:12,33-43` | Pick the URL per build environment, like `MobileHostService.configuration`. | machost |
| blocker | Backend | The prod env is "configured, not deployed": `REPLACE_WITH_PROD_HYPERDRIVE_ID`. The dev Worker accepts prod Stack tokens and writes to the `cmux-next-ios-dev` DB role. | `backend/wrangler.jsonc:31,36-39,42-55`; `mh:cmux-next-ios/SECURITY.md:97` | A prod PlanetScale branch and role, Hyperdrive with caching off, the prod Worker on a custom domain, and dev stops accepting the prod project. | machost |
| blocker | iOS config | The Release config has no `CMUX_MOBILE_API_BASE`, no DEBUG flag and no entitlements. `apiBase` is nil, so live data never starts. | `project.yml:27`; `CK/CmuxMobileAuth/CmuxMobileAuthModel.swift:122`; `CK/CmuxMobileShell/RootView.swift:227` | Remove Release, or make it equal Production. | unowned |
| major | Host script | `run-host.sh` defaults to the dev Worker even with `--prod`. The refresh token is a plaintext 0600 file. There is no LaunchAgent and no auto-update. | `scripts/host/run-host.sh:30,88-92`; `scripts/host/README.txt:11,21` | Retire it in favor of the app-supervised host, or fix it. | machost |
| major | Backend | No HTTP rate limiting. `/v1/ice` mints Cloudflare TURN credentials (4 h TTL) for any signed-in user of either project. Invites are unlimited. | `backend/src/ice.ts:17`; `backend/src/index.ts:144-147,260-268` | Per-user rate limits and short TURN TTLs. | unowned |
| major | Backend | TURN failure is silent. It falls back to STUN only, the `turn` flag is dropped from the response, and off-LAN WebRTC fails with no explanation. | `backend/src/ice.ts:37-42`; `backend/src/index.ts:146` | Return the `turn` state and show it in the app. | fastconn |
| major | Backend | Sockets never re-check auth after upgrade. Sign-out, token expiry or leaving the team never closes a socket. Relay sessions live 24 h. | `backend/src/index.ts:201-213`; `backend/src/team-hub.ts:30` | Expire on token exp, and close on membership change. | machost |
| major | Backend | A JWKS fetch failure returns 401 `keys_unavailable`, not 503. Clients treat it as a bad token, and this was observed live. | `backend/src/auth.ts:94-96`; `verify/connectivity.md:162-166` | 503 plus client retry. | unowned |
| major | Backend | Free plan on `workers.dev`. The DO relay budget is about 100 Mbit/s per socket, frames over the rate are dropped silently, relay RTT is 240-370 ms, and WireGuard bulk transfer over the relay failed 3 of 3. | `backend/src/team-hub.ts:43,205`; `verify/connectivity.md:31-71,155-161` | A paid plan, batching, and TURN-first. | fastconn |
| major | Backend | No APNs pipeline: no push-token route, no sender. | `backend/src/index.ts:134-270` | Push-token registration and an APNs sender. | unowned |
| major | Invites | Invites are email only. The dev invite callback is `http://localhost:8102`, and the prod callback `cmux.com/handler/team-invitation` is unverified. The app has no URL handling and no associated domains, so links open the website. The non-live share-link path POSTs without the required `{email}`. | `backend/wrangler.jsonc:17,32,42`; `CK/CmuxMobileShell/ShellModel.swift:172-187`; `CK/CmuxMobileAuth/CmuxMobileAuthModel.swift:291-303`; `CK/CmuxMobileShell/TeamSidebar.swift:67` | Universal links, a verified callback, and link invites. | unowned |
| minor | Backend | Test shortcuts (invite no-op, test JWKS) sit in production code paths, gated only by the `ENVIRONMENT` var. | `backend/src/auth.ts:55`; `backend/src/stack.ts:36-40,55`; `backend/src/team-hub.ts:124` | Compile them out, or assert prod. | unowned |
| minor | Backend | Data hygiene problems:<br>- `devices.last_seen_at` is never written.<br>- `kind` has no CHECK constraint.<br>- DO `macs` rows outlive team membership, so former members' Macs stay visible.<br>- Each `cmux-mobile-dial` registers a new phone. | `backend/src/store.ts`; `backend/drizzle/0000_init.sql:5`; `backend/src/index.ts:223-235`; `verify/connectivity.md:167` | Cleanup jobs and constraints. | unowned |
| minor | Rust | Signaling and channel queues are unbounded per link. | `rust/crates/cmux-mobile-link/src/signaling.rs:261,422`; `rust/crates/cmux-mobile-link/src/link.rs:436-447` | Bounds. | unowned |

### Security and device trust

| Severity | Area | What's fake / missing / unverified | Evidence | What production needs | Owner |
| --- | --- | --- | --- | --- | --- |
| blocker | Device identity | Clients choose their own `deviceId`. The same id evicts the live socket. The phone identity is a UUID plus a Stack token. `wgPublicKey` is never sent, and hostd's `wg_public_key` is always None. WireGuard and DTLS keys travel through the Worker, so the Worker is a trusted man in the middle. | `backend/src/index.ts:152`; `backend/src/team-hub.ts:149-155`; `CK/CmuxMobileLive/DeviceIdentity.swift:48`; `CK/CmuxMobileLive/LiveAPI.swift:57`; `rust/crates/cmux-mobile-host/src/host.rs:108`; `rust/crates/cmux-mobile-link/src/dial/wireguard.rs:752,837` | A per-install keypair pinned at pairing, with link keys signed by it. | machost (trust policy goes to #13742 first) |
| blocker | Mac admission | The Mac admits any phone whose `fromUserId` matches the owner. There is no approval prompt. The daemon allowlist includes `send` and `send-key`, so a leaked token is remote command execution. `SECURITY.md:22` claims a copied credential cannot get in, which is wrong. | `mh:cmux-next-ios/rust/crates/cmux-mobile-host/src/host.rs:150,170-172`; `rust/crates/cmux-mobile-host/src/policy.rs:45-46`; `mh:cmux-next-ios/SECURITY.md:18-23` | First-pair approval on the Mac before any daemon lane opens. | machost (#13742) |
| blocker | Revocation | There is no DELETE route anywhere. On the Mac, Remove is not revocation: the phone re-registers on its next connect. The phone has no unpair. Sign-out leaves two server device rows per phone each time, including the `(presence)` duplicate. | `backend/src/index.ts:134-270`; `verify/connectivity.md:167-168`; `mh:MH/CmuxNextMobileHost/IPhoneHostService.swift:114`; `CK/CmuxMobileShell/RootView.swift:203`; `CK/CmuxMobileLive/LiveCoordinator.swift:172-173` | Unpair and revoke endpoints that close live sockets, plus a denylist or re-approval. | machost |
| blocker | Account deletion | "Delete account" is only a link to `cmux.com/account`. There is no backend cascade. | `CK/CmuxMobileSettings/SettingsPages.swift:49` | A real in-app deletion. | unowned |
| major | acpmux lane | `acpmux` is an unfiltered splice with no policy, unlike the daemon's strict allowlist. | `rust/crates/cmux-mobile-host/src/services.rs:251-300` | A method allowlist. | machost |
| major | Second Mac host stack | `MobileHostService` (irx v2) starts on every team sign-in, whatever the "Allow iPhone Connections" setting says. | `mh:MH/CmuxNextApp/Cloud/AppServices+Cloud.swift:62-65`; `mh:MH/CmuxNextApp/MobileHostService.swift:25` | Gate both hosts on the setting, or retire one. | machost |
| major | Face ID | The `requireFaceID` toggle is saved but nothing reads it, and LocalAuthentication is never imported. | `CK/CmuxMobileSettings/SettingsScreen.swift:90-96`; `CK/CmuxMobileModel/Settings.swift:84` | An app-lock gate, or remove the toggle. | unowned |
| major | Shared-team dial | The phone dials the first online Mac in the team regardless of owner. Protocol v1 allows only your own Macs. | `CK/CmuxMobileLive/LinkMachine.swift:189-195`; `PROTOCOL.md:63` | Filter on `ownerUserId`. | fastconn |
| major | Sign-out | Sign-out leaves the Feed store, the on-disk Feed archive and chat stores from the previous account. | `CK/CmuxMobileModel/Discovery.swift:143-153`; `CK/CmuxMobileLive/LiveCoordinator.swift:111-113` | Wipe per-account state. | unowned |
| minor | Keychain | A `SecItemAdd` failure is ignored, which can mint a new device id on every launch. | `CK/CmuxMobileLive/DeviceIdentity.swift:57` | Surface it and retry. | unowned |
| minor | Host project check | hostd checks only `sub`, not the Stack project. | `rust/crates/cmux-mobile-host/src/host.rs:171-173` | Check the project too. | machost |

### Mac integration (machost)

| Severity | Area | What's fake / missing / unverified | Evidence | What production needs | Owner |
| --- | --- | --- | --- | --- | --- |
| blocker | Packaging | hostd is bundled only on nightly-next, added just before this audit, and no run has been seen. Release bundling is skipped silently without `CMUX_NEXT_MOBILE_HOST_BIN`. Hardened runtime and notarization for hostd are untested, and nightly-next notarization is paused (Apple status 7000). | `mh:.github/workflows/nightly.yml:267-270,1592-1605,2424`; `mh:scripts/cmux-next/bundle-mobile-host.sh:20-23` | A green run, then `codesign -dv` and `spctl` checks on bin/cmux-mobile-host, and a notarized DMG. | machost |
| blocker | Never dogfooded | Every live run started hostd by hand. Nothing has run hostd supervised by the cmux-next app, including the stdin token handover and the acpmux handover. | `verify/e2e-live.md:11-19`; `verify/live.md:104` | A tagged cmux-next build with the toggle on, and a phone dialing it. | machost |
| major | Start failure | If `daemonSocket()` or `deviceID()` throws at start, the host never retries until the account or toggle changes. | `mh:MH/CmuxNextMobileHost/IPhoneHostService.swift:~196-202` | Retry with backoff on daemon readiness. | machost |
| major | Token errors | A failed `sendToken` is only logged, so the UI says "Connecting…" forever. The phone-list read has no 401 refresh. | `mh:MH/CmuxNextMobile/MobileHost/MobileHostSupervisor.swift:184-193`; `mh:MH/CmuxNextMobileHost/IPhoneHostService.swift:90-107` | Show the error, refresh the token, retry. | machost |
| major | File roots | `CMUX_MOBILE_FILE_ROOTS` is just the chat roots, and none exist by default, so every file and artifact preview is refused. The e2e run set the roots by hand. | `mh:MH/CmuxNextMobileHost/IPhoneHostService+Wiring.swift:67-71` | Include workspace cwds, or prompt the user. | machost |
| major | Account model | The irx host needs a team, while hostd falls back to the personal space. | `mh:MH/CmuxNextApp/Cloud/CloudMobileAuth.swift:17` | One account model. | machost |
| major | Tests | Supervisor tests use a shell-script hostd. Crash/restart, backoff, `need_token` refresh and the toggle/reconcile paths are not covered. | `mh:Packages/macOS/CmuxNext/Tests/CmuxNextMobileTests/MobileHostTests.swift:87-125` | Add those tests. | machost |
| minor | Crash UX | Settings shows raw text such as "cmux-mobile-host exited with status 101". There is no crash-loop cap, no telemetry, and no SIGKILL escalation. | `mh:MH/CmuxNextMobile/MobileHost/MobileHostSupervisor.swift:97-98,130`; `mh:MH/CmuxNextMobile/MobileHost/MobileHostProcess.swift:94-101` | User-facing copy and a give-up state. | machost |
| minor | Two hostd copies | The cmux-next-ios hostd lacks machost's `F_GETPATH` symlink re-check (+35 lines in `services.rs`). | `rust/crates/cmux-mobile-host/src/services.rs` vs `mh:` | One source of truth. | machost |
| minor | Phone names | Phones are listed as "iPhone ab12" (a device-id prefix). | `mh:MH/CmuxNextMobileHost/IPhoneHostService+Page.swift` | The device name. | machost |

### Chief, agent chat and Feed

| Severity | Area | What's fake / missing / unverified | Evidence | What production needs | Owner |
| --- | --- | --- | --- | --- | --- |
| blocker | Chief | Production Chief is `ChiefOfflineBackend`. hostd serves only `echo`, `daemon`, `acpmux` and `file`, and no `conversation-*` command is allowlisted. Chief parity was verified only on the mock. | `rust/crates/cmux-mobile-host/src/services.rs:33-39`; `rust/crates/cmux-mobile-host/src/policy.rs:15-140`; `CK/CmuxMobileChief/ChiefSession.swift:21-34`; `verify/chief-parity.md:86-88,132-135`; `scripts/demo-build.sh:364-366` | A Chief service or allowlist entry (a trust decision on #13742), then a live verification. | chieflive |
| blocker | Compose to Chief | `sendWhenConnected` waits forever on the offline backend, and `ChiefSession.use` replaces the store, so the queued message is lost with no error. | `CK/CmuxMobileChief/ChiefCompose.swift:169`; `CK/CmuxMobileChief/ChiefOfflineBackend.swift:17-21`; `CK/CmuxMobileChief/ChiefSession.swift:51-55` | Queue on the session, or fail visibly. | chieflive |
| major | Chief status | `LiveCoordinator.chiefStatus` is never displayed. Chief says "isn't connected to a Mac" even when the Mac is connected but has no Chief. | `CK/CmuxMobileLive/LiveCoordinator.swift:29,409,418`; `CK/CmuxMobileChief/ChiefOfflineBackend.swift:11` | Show the real reason. | chieflive |
| blocker | Permissions | Allow and question answers from the phone always fail with `permission.person_required`. The Feed's Allow swipe and buttons and the chat answer cards look live anyway. | `CK/CmuxMobileLive/AcpmuxHub.swift:366`; `CK/CmuxMobileFeed/FeedSwipe.swift:254`; `CK/CmuxMobileFeed/FeedCell.swift:59,212`; `CK/CmuxMobileAgentChat/AgentChatScreen.swift:673`; `verify/live.md:146-164` | A signed approval path decided on #13742, or decline-only UI until then. | unowned (#13742) |
| blocker | Chat attachments | Files-picker chips carry only a name and are not sent ("carry no contents yet"). A file-only message sends an empty prompt. | `CK/CmuxMobileAgentChat/ChatComposer.swift:58-61`; `CK/CmuxMobileLive/AcpmuxHub.swift:247-262` | Upload or inline the bytes, or remove the Files item. | unowned |
| major | Live agents | Every live agent run used a scripted ACP agent (`fake_agent.py`, `e2e_agent.py`). No real Claude or Codex turn has gone over the link. | `verify/live.md:98-99`; `verify/e2e-live.md:15-17` | One e2e run with a real harness. | unowned |
| major | Starting chats | The phone cannot start an agent chat: hostd refuses `cwd` and `agent-session-start`. | `verify/e2e-live.md:45,116-122`; `CK/CmuxMobileLive/LiveCoordinator.swift:524-552` | A policy decision, then wiring. | unowned |
| major | Checkpoints | Listing and restoring checkpoints always throw live, but the menu item is always shown. | `CK/CmuxMobileLive/AcpmuxHub.swift:265-271`; `CK/CmuxMobileAgentChat/AgentChatScreen.swift:705`; `CK/CmuxMobileWorkspaces/WorkspaceTabsSource.swift:278` | A link method, or hide the item. | unowned |
| major | Plan mode | The toggle hard-codes `"plan"`/`"default"`, so Codex mode names fail. It is shown even when `modes` is empty. | `CK/CmuxMobileAgentChat/ChatComposer.swift:167-169` | Use the advertised modes. | unowned |
| major | @mention | Search covers only files seen in the transcript, not the project. | `CK/CmuxMobileAgentChat/ChatComposer.swift:364-366` | Project file search over the `file` channel. | unowned |
| major | Silent drops | Prompts are dropped when the link is gone, after the composer has already cleared. Answers to a question missing from the map are dropped and the card stays pending. | `CK/CmuxMobileLive/AcpmuxHub.swift:216,231` | Throw, and keep the draft. | unowned |
| major | Feed replies | The reply is shown locally first. If the tab isn't found the handler returns silently, and errors land in the chat store, not the Feed. | `CK/CmuxMobileFeed/FeedCell.swift:276-281`; `CK/CmuxMobileFeed/FeedScreen.swift:85-88` | Optimistic state with a failure state. | unowned |
| major | Feed refresh | Pull-to-refresh only sleeps 600 ms. | `CK/CmuxMobileFeed/FeedScreen.swift:73` | Re-sync, or remove it. | unowned |
| major | Feed fallback | When `actions` is nil, the Feed marks the item "Allowed"/answered locally without sending anything. | `CK/CmuxMobileFeed/FeedStore.swift:244,303` | Throw instead. | unowned |
| major | Home actions | Delete, Unread and Hide Alerts are temporary view state that resets on relaunch. "Needs you" flags only the workspace's first agent. Feed mute is not persisted. | `CK/CmuxMobileChief/ConversationsHome.swift:37-39,89,151-174`; `CK/CmuxMobileFeed/FeedStore.swift:124` | Persist them and make them act on the Mac. | unowned |
| major | "Changes" | Labeled "working tree" but shows only the agent's edits in loaded history. There is no whole-tree diff. | `CK/CmuxMobileAgentChat/AgentChatScreen.swift:89-95` | A git diff over the link, or relabel. | unowned |
| minor | Small gaps | - "Stop agent" is always enabled.<br>- An empty diff card appears for unparsed edits.<br>- Compose to a single agent drops images.<br>- Markdown has no image block.<br>- Diff "viewed" marks are in memory only. | `CK/CmuxMobileAgentChat/AgentChatScreen.swift:256,661`; `CK/CmuxMobileChief/ChiefCompose.swift:157`; `CK/CmuxMobileMarkdown/MarkdownDocument.swift:35-42`; `CK/CmuxMobileDiff/DiffViewer.swift:17` | Fix each. | unowned |
| major | Handoff | Live handoff was never exercised and may be refused for remote callers. | `verify/acp-parity.md:101-102` | A live run. | unowned |

### Terminal, workspaces, browser, artifacts

| Severity | Area | What's fake / missing / unverified | Evidence | What production needs | Owner |
| --- | --- | --- | --- | --- | --- |
| blocker | New tab | New Claude/Codex/Terminal/Browser tabs only call `AppStore.appendTab`, which edits a local array. Nothing reaches the Mac. The next refresh wipes the tab, a new terminal stays on "Connecting…" forever, and a new chat points at a tab the Mac doesn't have. | `CK/CmuxMobileWorkspaces/WorkspaceTabsSource.swift:143-165`; `CK/CmuxMobileModel/AppStore.swift:111-115,215-220` | A daemon create-tab call, and show the tab only once the Mac confirms. | unowned |
| blocker | Close tab | Close only removes the tab locally, and it comes back on refresh. | `CK/CmuxMobileWorkspaces/WorkspaceTabsSource.swift:128-137`; `CK/CmuxMobileModel/AppStore.swift:225` | A daemon close call. | unowned |
| blocker | Terminal attachments | `send()` puts `~/.mobile/uploads/<name>` in front of the text and presses Return. Nothing uploads the file; the comment says "the mock does not upload". Photo names are invented as `IMG_\(1000+i)`. Video and camera are absent. | `CK/CmuxMobileTerminal/Screen/TerminalModel.swift:164-173,237-240`; `CK/CmuxMobileTerminal/Composer/TerminalComposer.swift:110,127` | An upload channel to the Mac that returns the real path. Hide the + menu until it exists. | termlive |
| major | Pending input | Text typed while a terminal is connecting is dropped. The placeholder does not block the composer. | `CK/CmuxMobileTerminal/Session/PendingTerminalSession.swift:28`; `CK/CmuxMobileTerminal/.../TerminalConnectingView.swift:58` | Queue the input, or disable the composer. | termlive |
| major | Refused input | When the Mac refuses keystrokes or a resize, the error is only logged and the keys are lost. | `CK/CmuxMobileLive/DaemonTerminalSession.swift:257-260` | Show the error and retry. | termlive |
| minor | Resize policy | The phone resizes the Mac's terminal, and the shared-sizing policy is unresolved. A first prompt was once lost after a resize. | `verify/polish.md:142-145`; `verify/e2e-live.md:155-157` | A policy decision and a test. | termlive |
| major | Endless Connecting | When terminal or agent channels fail to open, the error is only logged, so the banner says Connected while the list is empty. The placeholder never times out and offers no retry. | `CK/CmuxMobileLive/LiveCoordinator.swift:271,300,352-364` | Error, timeout and retry states. | fastconn |
| blocker | Paired Macs | Status is hardcoded: "Online · X direct" or "Last seen 3h ago". The real `macLinkStatus` and `lastSeenAt` exist but are unused. | `CK/CmuxMobileSettings/SettingsPages.swift:111`; `CK/CmuxMobileModel/Team.swift:97` | Bind to real state. | fastconn |
| major | Mac picker | In live mode the picker lists only the linked Mac, and there is no UI to switch Macs. | `verify/workspace-create.md:174-175`; `verify/live.md:190-191` | Multi-Mac selection. | fastconn |
| major | Browser | Browser tabs load a local WKWebView on the phone ("A streamed Mac browser replaces this later"), so Mac `localhost` pages and sessions don't work. `.link` previews behave the same. | `CK/CmuxMobileWorkspaces/BrowserTab.swift:7-9`; `CK/CmuxMobileArtifacts/LinkFileArtifactSource.swift:26-27` | Merge the browserstream branch (`611880d6`). | browserstream |
| major | File browser | Folders and `~` paths can't be previewed, and there is no file browser (SPEC 11.2). | `CK/CmuxMobileArtifacts/LinkFileArtifactSource.swift:28-29,46` | A directory listing over `file`. | unowned |
| major | Workspace creation | No directory choice, no agent first tab, no git clone. `new-workspace` probably moves the Mac app's view. | `CK/CmuxMobileLive/LiveWorkspaceCreation.swift:23-25`; `verify/workspace-create.md:170-171` | Implement, plus per-client focus. | unowned |
| minor | Dead fakes in the binary | These ship in Production but are unreachable or inert:<br>- `TerminalTabContent` default "Last login: Sun Oct 12…" page<br>- "Mock session · local" label<br>- `DemoDirector`/`WorkspaceDemoDirector`<br>- mock user "Aziz Albahar"/`424242` in `CmuxMobileAuthModel`<br>- the Demo config sets DEBUG on the app target only, not on CmuxMobileKit | `CK/CmuxMobileWorkspaces/TerminalTabContent.swift:72-112`; `CK/CmuxMobileTerminal/Screen/TerminalScreen.swift:68`; `CK/CmuxMobileDesign/DemoDirector.swift`; `CK/CmuxMobileAuth/CmuxMobileAuthModel.swift:136,251`; `project.yml:30` | Wrap them in `#if DEBUG` and add them to `check-production-binary.sh`. | unowned |

### Settings, onboarding, App Store

| Severity | Area | What's fake / missing / unverified | Evidence | What production needs | Owner |
| --- | --- | --- | --- | --- | --- |
| blocker | Apple sign-in | The Stack SDK uses native Apple sign-in, which needs the `com.apple.developer.applesignin` entitlement. No config has it: Production has only keychain groups, and Debug/Demo have no entitlements file. Apple, Google and GitHub sign-in were never run end to end. | `App/CmuxMobileApp-Production.entitlements`; `project.yml:71-75`; `CK/CmuxMobileOnboarding/Welcome.swift:234-236`; `verify/login.md:77` | Add the capability, then run each provider on a Production build. | unowned |
| blocker | Push / Live Activities | Setup promises push and Live Activities and asks for permission. There is no `aps-environment`, no remote registration, no ActivityKit, no widget extension and no background refresh. The notify toggles and Live Activities picker are never read. | `CK/CmuxMobileOnboarding/Setup.swift:324-333`; `CK/CmuxMobileSettings/SettingsPages.swift:211-221` | Build APNs and Live Activities, or hide the UI. | unowned |
| major | Dead settings | These are saved but never read: `showConnectionDetails`, `terminalFontSize`, `terminalTheme`, `wrapCode`, `keyClicks`, `dismissKeyboardAfterSend`, `followUp`. Only `transport`, `appearance` and `haptics` take effect. | `CK/CmuxMobileModel/Settings.swift:73-83`; `CK/CmuxMobileSettings/SettingsPages.swift:127,136-141` | Wire them up, or remove them. | unowned |
| major | Team members | The list shows only "You". | `CK/CmuxMobileSettings/SettingsPages.swift:78-87` | Load the real team members. | unowned |
| major | Team color | Editing color or icon from Settings saves only locally. The sidebar path does upload. | `CK/CmuxMobileSettings/SettingsScreen.swift:144`; `CK/CmuxMobileShell/ShellModel.swift:157-168` | Share the upload path. | unowned |
| major | Account page | "Sign-in methods" is placeholder copy. | `CK/CmuxMobileSettings/SettingsPages.swift:42` | Real linked providers. | unowned |
| major | Silent errors | Several failures are swallowed with no message to the user:<br>- `WorkspaceSync.lastError` and `AcpmuxHub.lastError` are never shown.<br>- Team colors load through `try?`.<br>- Stack team selection uses `try?`.<br>- Email code resend uses `try?`. | `CK/CmuxMobileLive/LiveCoordinator.swift:271,300`; `CK/CmuxMobileAuth/CmuxMobileAuthModel.swift:260`; `CK/CmuxMobileOnboarding/EmailSignIn.swift:200` | Show the errors. | fastconn |
| major | App Store path | Several pieces are missing:<br>- The Production bundle id is `dev.cmux.mobile.prod`.<br>- Signing uses development profiles only, with no App Store export.<br>- No privacy manifest.<br>- No `ITSAppUsesNonExemptEncryption`.<br>- No local-network usage string.<br>- No versioning in `project.yml`. | `project.yml`; `scripts/demo-build.sh` | Decide the shipping identity, then add an export, a manifest and an encryption declaration. | unowned |
| minor | Acknowledgements | Only three hardcoded entries; WireGuard, WebRTC, uniffi and others are missing. | `CK/CmuxMobileSettings/SettingsPages.swift:246-248` | Generate the list. | unowned |
| minor | Cached profile | The user's name and email are cached in UserDefaults (tokens are correctly in the Keychain). | `CK/CmuxMobileAuth/CmuxMobileAuthModel.swift:98` | Keychain, or clear on sign-out. | unowned |

### Spec features not implemented

| Severity | Area | What's missing | Evidence | Owner |
| --- | --- | --- | --- | --- |
| major | Browser streaming | Covered above. | `CK/CmuxMobileWorkspaces/BrowserTab.swift:7-9` | browserstream |
| major | Search tab (SPEC 13) | The tab bar has 4 tabs, with no Search. | `CK/CmuxMobileShell/RootView.swift:392-403` | unowned |
| major | File browser, whole-tree diff, @mention project search, checkpoint restore, chat attachments, video | Covered above. | see rows above | unowned |
| major | Plan approve / keep planning (SPEC 6.7) | There are no plan action buttons. | SPEC 6.7 vs `CK/CmuxMobileAgentChat` | unowned |
| minor | Terminal (SPEC 10.3-10.4) | No key bar customization, terminal camera, full-screen joystick, or long-press selection. | SPEC 10 vs `CK/CmuxMobileTerminal` | termlive |
| major | Push, Live Activities, background refresh | Covered above. | see rows above | unowned |

### Verification honesty

| Severity | Area | What's unverified | Evidence | What production needs | Owner |
| --- | --- | --- | --- | --- | --- |
| major | Mock-only verification | These were verified only with `CMUX_MOBILE_MOCK_AUTH=1`, mock sessions or DemoDriver: shell, workspaces, chat-feed, chat-dogfood, acp-parity, toggles, swipes, keyboard, jump-button, navigation, tabskit-sync, login. | `verify/chat-feed.md:81`; `verify/swipes.md:43`; `verify/tabskit-sync.md:85`; `verify/chat-dogfood.md:11-12` | Repeat the key flows live on a Production build. | unowned |
| major | Stub TUI | The `daemon` channel ran only against `cmux-mobile-stub-tui`, not real cmux-tui, in the connectivity work. | `verify/connectivity.md:6,194,238` | A real cmux-tui run. | termlive |
| major | Networks | Every live run was behind one NAT. "Distant" was simulated with relay-only mode, and the Freestyle and AWS runs were not done. No cellular run. | `verify/connectivity.md:87-95,208-216,241` | A cellular phone, or a VM on another network. | fastconn |
| major | Credentials | Every live run used dev Stack or the DEBUG credential. Production sign-in was never run end to end by an agent. | `verify/live.md:106-111`; `verify/e2e-live.md:22-25` | A prod-config run. | machost |
| major | Fakes in tests | Rust tests use `FakeSignaling` and loopback. Backend tests use a fake JWKS, `STACK_TEST_TEAMS` and the memory store. `pgStore` and the migrations were never tested against Postgres. | `rust/crates/cmux-mobile-link/tests/loopback.rs`; `rust/crates/cmux-mobile-host/tests/host.rs`; `backend/vitest.config.ts:5-31`; `backend/src/store.ts:149-152` | Postgres integration tests and a real-NAT soak. | unowned |
| major | Tests not run | `nx-remote` could not resolve `cmux-lawrence-2`. CmuxMobileTerminalTests, CmuxMobileModelTests and TeamTests were written but never run. Other suites ran with a local `xcodebuild test`, against HQ policy. | `verify/terminal.md:146-149`; `verify/shell.md:79`; `verify/toggles.md:77`; `verify/chat-feed.md:27-29`; `verify/navigation.md:87-88`; `verify/workspaces-chief.md:96` | Re-run every suite on the build host or CI and record the results. | unowned |
| major | PLAN verification bar | No Instruments hitch trace exists anywhere. iOS 27 recordings are missing for live, pairing, tabskit-sync and the connectivity app run. Light mode is missing for live. | `verify/terminal.md:108-110`; `verify/live.md:194`; `verify/tabskit-sync.md:80` | Device traces and the missing recordings. | unowned |
| major | Evidence | `verify/evidence/` is git-ignored and absent, so every "Pass" has no checkable artifact. | `verify/live.md:5`; `verify/e2e-live.md:6` | Publish the artifacts or attach them to PRs. | unowned |
| major | Touch input | Gestures were driven through state paths or private UIKit entry points. Fixes for bugs found on the real phone (jump button, keyboard) were checked only on simulators. | `verify/workspaces-chief.md:165-171`; `verify/polish.md:150-152`; `verify/jump-button.md:106-108`; `verify/keyboard.md:84` | Device runs, when the user authorizes them. | unowned |
| minor | Long transcripts | The transcript is a plain VStack, so a 2000-record history lays out fully. Never profiled. | `verify/polish.md:156-158` | A device profile. | unowned |

## What is genuinely solid

- **Mock content is compiled out of Production** (7584b3b1):
  - Mock Chief, terminal, agent, Feed, artifacts and workspace creation.
  - `MockMacLink` and `DemoDriver`.
  - Developer options are hard-off and their stored values are wiped at launch.
  - Placeholders are honest: offline Chief, the "Connecting…" terminal, `UnavailableArtifactSource`.
- **Backend JWT checks:** ES256 only, issuer and audience checked per project, anonymous users rejected. Membership errors fail closed, and `fromUserId` is always stamped by the server.
- **hostd policy:**
  - The daemon allowlist strips `argv`, `cwd` and `env`.
  - The `file` service confines paths to the shared roots, with symlinks checked.
  - acpmux is loopback only.
  - Frame-size caps, and no panics on network input.
- **Test code** is behind a feature: the Rust `testing` module and `cmux-mobile-fake-backend`.
- **Live paths that work:** the live terminal (reattach, keystrokes kept for retry, resize, scrollback replay), the live chat prompt/cancel/model/mode, real file previews, and the live Feed.
