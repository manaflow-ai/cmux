# Production acceptance criteria (overnight verification)

Author: orchestrator session (acceptance author role). Judged by a FRESH independent
verifier session per round, against artifacts captured from the exact build SHA under
review (evidence manifest: state → artifact → SHA). Implementers never judge their own work.

## Platform matrix

- iOS: headless simulators, iOS 26.5 and iOS 27.0, iPhone 17 Pro, software keyboard, dark + light, default and largest accessibility text size.
- Mac: a REAL cmux-next app build (tagged, isolated config, launched hidden) with the bundled cmux-mobile-host; real daemon and acpmux. No standalone helpers, stubs, fake agents or mock links for any "pass".
- Backend: dev Worker for the rig (dev Stack); prod Worker smoke via the prod test account.
- Physical iPhone: NOT available overnight; any phone-only criterion is reported "blocked (needs device)", never passed from simulator evidence.

## User journey (each must pass with recording + per-step screenshots)

1. Fresh install → welcome intro (≈5 s, no dropped-frame stalls >50 ms) → sign in → team/personal choice with a loading state (never a false "Create Team").
2. Mac appears within 3 s of the Mac app enabling Mobile; status is truthful (green only when this phone is connected).
3. Workspaces list shows the Mac's real workspaces; filter by Mac; search; long-press menu; trailing swipe actions render correctly in dark mode; no leading swipe actions.
4. Create workspace: instant, opens its terminal, row confirms; Mac-side workspace exists.
5. Terminal: attaches to the Mac's real shell (no mock output ever); typing via composer and direct tap; arrows/joystick; ^C; vim/htop alt-screen pinned to the composer; scrollback smooth; Files & Links lists and previews real files; image upload lands on the Mac and the real path is inserted (no auto-Return).
6. Agent chat (real harness only; blocked if none is free): stream, tool calls, diff viewer, artifacts, permission Allow (Face ID) and Deny reach the agent, question answer reaches the agent, attachments delivered as ACP content.
7. Feed: events from the Mac appear; inline answer/allow/deny reach the Mac; quote bubbles right-aligned; persists across relaunch.
8. Chief: the Mac's real Chief conversation (no mock), send/receive, typing, model selection works; details-page controls either work (with native switch animation) or are absent.
9. Settings: transport switch WebRTC ↔ WireGuard and relay-only all reconnect; device list with Remove; sign out returns to Welcome and fully resets; account deletion path present.
10. Resilience: app background/foreground, Mac app quit/relaunch, signaling reset (Worker redeploy) → automatic reconnect + terminal reattach, no false errors, no stuck "Connecting…".
11. Every control does something real; no placeholder data; no lying empty states; no leftover demo strings in Production (`check-production-binary.sh --shipping` passes).

## Latency (median / p95 over ≥ 20 samples, LAN)

| Metric | Target |
| --- | --- |
| Cold launch → workspaces live | ≤ 1.5 s / ≤ 2.5 s |
| Warm reconnect (foreground) | ≤ 1.0 s / ≤ 1.5 s |
| Keystroke → echo, idle | ≤ 50 ms / ≤ 80 ms |
| Keystroke → echo, under output flood | ≤ 80 ms / ≤ 150 ms |
| Tab switch | ≤ 150 ms |
| Agent stream first token after send (excluding model time) | ≤ 300 ms overhead |

## Performance

Instruments (Animation Hitches / Time Profiler) on the simulator for: Workspaces scroll, terminal fling scroll, agent transcript scroll, keyboard show/hide/drag. No hitch > 33 ms in steady scrolling; no main-thread stall > 100 ms on navigation.

## Design

Each UX area converged through a designer ⇄ implementer loop with a written sign-off and side-by-side comparisons against the named references (ChatGPT, Claude, Grok, Messages, Safari tabs).

## Gate

Upload to TestFlight (cmux INTERNAL, 1.1.0) only after a fresh verifier approves a full round (all journey steps pass or are explicitly "blocked (needs device)", latency targets met, no blocker in production-audit.md open) AND CI signing is unblocked (currently on hold by the user).
