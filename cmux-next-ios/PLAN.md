# cmux-next-ios: native iOS app for cmux-next

Independent effort on branch `feat-cnx-ios`. Native, mainstream-AI-app feel
(ChatGPT / Claude / Grok); cmux-next theme only where it is free.

## Layout

| Path | What |
| --- | --- |
| `cmux-next-ios/project.yml` | XcodeGen app project (`CmuxMobileApp`), iOS 26.0+, bundle `dev.cmux.mobile` (+ `.<tag>`). Configurations: Debug, Release, Demo (-O with the DEBUG developer surface), Production (-O, no DEBUG, production Stack project, `dev.cmux.mobile.prod`). `scripts/demo-build.sh [--config Production]` builds Demo or Production installs. TestFlight (`dev.cmux.app.internal`, "cmux INTERNAL", App Store signing, production Worker): `scripts/testflight-build.sh`, see `verify/testflight-readiness.md`. |
| `cmux-next-ios/CmuxMobileKit/` | SwiftPM package with all app modules (below). |
| `cmux-next-ios/rust/` | Rust crates: `cmux-mobile-link` (transport-agnostic framed channel mux, WebRTC + WireGuard dialers), `cmux-mobile-link-ffi` (uniffi), `cmux-mobile-host` (Mac bridge). |
| `cmux-next-ios/backend/` | Cloudflare Worker `cmux-mobile-api` (DO `TeamHub`: signaling, presence, WireGuard relay) + PlanetScale Postgres `cmux-next-ios` via Hyperdrive (device registry, team prefs). |
| `cmux-next-ios/verify/` | Recording / frame-split / comparison scripts and the evidence index. |

## CmuxMobileKit modules

- `CmuxMobileDesign`: tokens (true-black dark, glass chrome, cmux accent derived minimally), team colors, motion springs.
- `CmuxMobileModel`: Team, Mac, Workspace, Tab (terminal / browser / agent / chief), FeedEvent, AgentQuestion, Artifact, Diff.
- `CmuxMobileTransport`: `MacLink` protocol (open channel, request/reply, event stream), `TransportKind {webrtc, wireguard}` switch, mock link for UI work. Backed by `cmux-mobile-link-ffi`.
- `CmuxMobileAuth`: wraps `CmuxAuthRuntime` (Stack Auth: Apple, Google, GitHub, email code).
- `CmuxMobileLive`: live data once signed in: device registration, presence, the Mac link state machine (dial, backoff, transport switch), daemon workspaces, acpmux chats, Feed events and answers, Chief over the link. See `verify/live.md`.
- Feature modules: `CmuxMobileOnboarding`, `CmuxMobileShell` (TabView + team sidebar), `CmuxMobileHome` (Chief via `CmuxConversation`), `CmuxMobileWorkspaces` (`CmuxTabsKit`), `CmuxMobileFeed` (WKWebView markdown cards, inline answers, quote bubbles), `CmuxMobileTerminal` (Ghostty, composer, key bar, joystick), `CmuxMobileAgentChat`, `CmuxMobileArtifacts`, `CmuxMobileDiff`, `CmuxMobileSettings`.

## Shared packages: byte-identical to upstream

cmux-next-ios never patches the shared iOS packages it builds on. Both must stay
byte-identical to their upstream branches:

| Package | Upstream branch |
| --- | --- |
| `Packages/iOS/CmuxTabsKit` (Safari-style tabs UX) | `origin/feat-cmux-next-tabs-kit` |
| `Packages/iOS/CmuxConversation` (Chief transcript) | `origin/feat-imsg-parity-gui` |

`scripts/check-tabskit-sync.sh` checks both (exit 1 on drift);
`scripts/demo-build.sh` runs it before every Demo or Production build, warns
loudly and records drift in `MANIFEST.md`, and fails with `--strict`. Sync with
`git checkout origin/<branch> -- Packages/iOS/<Package>`. Anything cmux-next-ios needs
beyond the package goes in host code (`CmuxMobileWorkspaces`, `CmuxMobileShell`, `CmuxMobileHome`)
or, as a proposal only, in `verify/tabskit-upstream-requests.md` and
`verify/imsg-upstream-requests.md`.

## Mac side

`cmux-mobile-host` runs beside the cmux-next daemon on the Mac. The cmux-next app
bundles it and runs it itself (Settings > Mobile; `rust/README.md`
"Supervised by the cmux-next app"); `run-host.sh` in the demo host package is
for Macs without the app. It registers the Mac with `cmux-mobile-api`, answers WebRTC offers and
WireGuard handshakes, and splices link channels to the cmux-tui socket
(protocol v12 JSON lines), acpmux, and terminal byte streams.

## Milestones

1. Shell: launch, onboarding, sign in, tabs, team sidebar, settings, mock data. Recorded and compared.
2. Backend + Rust link: signaling, presence, TURN credentials; WebRTC and WireGuard dial from simulator to `mini-cmuxs-mac-mini-2`.
3. Terminal: Ghostty render, smooth scroll, keyboard-pinned composer, attachments, key bar, TUI mode.
4. Workspaces (TabsKit, last tab), agent chat (ACP parity), Chief (CmuxConversation adapter).
5. Feed, artifacts browser + previews, diff viewer.
6. Polish passes: frame-by-frame comparisons against references, performance traces.

## Verification bar

Every screen: simulator recording on iOS 26 and 27, frame split, side-by-side
with the matching reference capture, Instruments hitch check for scrolling and
transitions. Evidence goes in `cmux-next-ios/verify/evidence/<date>/`.
