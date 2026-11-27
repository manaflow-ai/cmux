# Acceptance: a simulator of the latest CI build connects to a Mac build (2026-10-21)

Criterion: "you can connect from a simulator representing the latest successful CI to a
Mac build." Result: **PASS**. Five of five live checks passed over the real link
(run 8, 2026-10-21 22:08 to 22:10 UTC).

## What ran

| Part | What |
| --- | --- |
| iPhone app | Source of the latest successful cmux INTERNAL upload: `d15e9a75c897` (1.2.0, build 20261021023124), workflow run 39533272979. The run used that commit plus this PR's commits (`c4af85db29e`). Configuration **TestFlight**: bundle `dev.cmux.app.internal`, no DEBUG, service `https://mobile-api.cmux.dev`, production Stack project `9790718f-…`. Simulator app made by `scripts/testflight-build.sh --unsigned --no-asc` with `CMUX_MOBILE_SIMULATOR_APP`, Xcode 26.6, on mini-cmux8s. The archived device app passed `check-production-binary.sh` (no DEBUG-only strings) |
| Simulator | One headless iPhone 17 Pro, iOS 26.5, on mini-cmux8s. Simulator.app was never opened. Driven by AXe (HID taps, software keyboard) and `simctl io` recording. Shut down and deleted after the run |
| Mac | Fleet build `d7105e8d34b5b8d700966860` (aws-m4pro-6), tag `cmux-mobile-acc-5c5fd157`, `--production` (a Debug app with `CMUX_AUTH_ENVIRONMENT=production`). Commit `5c5fd15790d6` is feat-cmux-next `96cb2bed124` plus this PR, and contains merge `f3842ffe4ce`. Bundled `cmux-mobile-host.version` reads commit `c4af85db…` (same tree). It ran hidden on mini-cmux11s (`open -g -j -n`), with every setting passed by `open --env`: its own `cmux-next.json` (`mobile.allowIPhoneConnections: true`), `CMUX_AUTH_CREDENTIALS_FILE` (0600) and `CMUX_NEXT_IPHONE_PAIRING_SEED`. The hostd talked to `https://mobile-api.cmux.dev` (`CMUX_MOBILE_BASE_URL`) |
| Account | The production Stack test account A from `~/.secrets/cnx-ios-userhub-verify/`, the same on both sides. It is never printed |
| Link | Phone (mini-cmux8s) to Mac (mini-cmux11s), two machines. WireGuard came up with `path=Turn`. The browser's media session went `path=Direct`, then switched to `wireguard-udp`. No local socket, loopback or debug shortcut |

The published nightly 1.0.0-nightly.3967575499801 (cmux-mobile-host 331e2e901ce) arrived
during the run and was not used. It is a Release build, so it ignores the credentials file
and the pairing seed. A hidden rig cannot sign it in or press Allow without a person.

Why not tip-of-branch for the Mac: on 2026-10-21 the feat-cmux-next tip did not build.
- #22778 left a sidebar compile error; open PR #22853 fixes it.
- #22839 left the Chief inspector page stale, so the fleet build's gen-strings check fails.

`d15e9a75` (the INTERNAL commit) also failed a fleet build on the inspector check, and
`806411a4` failed on the sidebar error. `96cb2bed124` is the newest commit that predates
both.

## Results (run 8)

| # | Check | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Sign in on both sides with the same production account | PASS. The phone was signed in 21.5 s after launch, by password, against the production project. The Mac signed in from its credentials file, and its hostd registered in `personal-735fc0a4…` | `shots/sign_in.png`; Mac `cmux-mobile-host.log` "registered device", "signaling connected" |
| 2 | The Mac appears on the phone | PASS. The connect step read "cmux11's Mac mini is online", then Workspaces listed the Mac's `acc-ws` live over the link | `shots/connect-mac-online.png`, `shots/mac_appears.png` |
| 3 | Pairing approved (the rig's pairing seed) | PASS. No approval banner and no failure on the phone. The Mac wrote `paired-devices.json`, and its services answered (they refuse an unpaired phone with `unpaired`) | `shots/paired.png`, `mac-hostd-excerpt.txt` |
| 4 | A terminal echoes typed text | PASS. Typed `echo acc62162$(echo ok)` in the composer; the phone's terminal shows the shell's output `acc62162ok` from `cmux@cmux11s-Mac-mini` | `shots/terminal_echo.png` |
| 5 | A browser tab loads a page | PASS. New Browser Workspace from the phone, `example.com`, page rendered (streamed from the Mac's browser host on the media lane) | `shots/browser-example.png`; Mac log "browser: host started", "media lane frames" |

Video of the whole run: `acceptance.mp4` (H.264, about 2 min).

Evidence (git-ignored, on the laptop that ran the check):
`~/cmux-mobile-builds/20261021-acceptance-latest-ci/evidence/run8/` holds `results.json`,
`run.log`, `acceptance.mp4`, `shots/` and `mac-hostd-excerpt.txt`.

## What had to change first (this PR)

These runs failed before this PR's fixes:

- Run 1: the phone signed in and saw the Mac online, then showed **"Pairing failed:
  keychain(-34018)"**. The TestFlight-config simulator app was unsigned, so it had no
  keychain group. `testflight-build.sh` now signs it ad hoc with the configuration's
  entitlements, which Xcode simulates in the binary.
- A shipping configuration cannot pair on a simulator at all, because the software P-256 key
  was DEBUG-only and the simulator has no Secure Enclave (userhub-prod-verify-20261020 D1).
  `PhoneKeys` now uses the software key in any simulator build. Device builds are unchanged.
- A shipping configuration has no password sign-in, and a test account gets no email code. A
  non-DEBUG **simulator** build now signs in once from `CMUX_MOBILE_STACK_EMAIL`/`PASSWORD`.
- A Debug Mac pointed at production ignored `CMUX_AUTH_CREDENTIALS_FILE`. It now reads that
  explicit file, and never the ambient secrets files. Release builds never read it.

Runs 2 to 7 were driver fixes: an ad hoc `application-identifier` that SpringBoard refused,
the status row a one-Mac list does not show, a `*` the typer could not reach, and OCR text
(example.com no longer says "Example Domain").

## How to rerun

```bash
# iOS: on a mini with Xcode 26.6 and the iOS Rust targets
CMUX_MOBILE_SIMULATOR_APP=$PWD/sim/CmuxMobileApp.app \
  cmux-next-ios/scripts/testflight-build.sh --ref <INTERNAL sha + this PR> --unsigned --no-asc \
  --marketing-version 1.2.0 --build-number <build> --config TestFlight
# Mac: cmux-ci build cmux --ref <sha> --tag <tag> --production, then launch hidden on another mini:
#   open -g -j -n --env CMUX_NEXT_CONFIG_FILE=... --env CMUX_AUTH_CREDENTIALS_FILE=... \
#     --env CMUX_NEXT_IPHONE_PAIRING_SEED=... (seed names the simulator) "<app>"
# Phone checks (credentials in the environment, never printed):
python3 cmux-next-ios/verify/e2e/acceptance_latest_ci.py --app sim/CmuxMobileApp.app \
  --bundle dev.cmux.app.internal --sim acc-latest-ci-ios26 \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-5 --workspace acc-ws --out <dir>
```

## Observation for the link owners

Two minis on the same LAN (172.20.21.x) linked over WireGuard on `path=Turn` and never went
Direct, while the WebRTC media session between the same two found `path=Direct` at once. The
user's laptop and phone show the same "never Direct on one LAN" pattern (nightly
331e2e901ce), followed there by REKEY_TIMEOUT drops over TURN.
