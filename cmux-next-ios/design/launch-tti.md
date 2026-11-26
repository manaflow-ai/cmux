# Launch to first interaction: the iPhone marks and bench

Leo, 2026-11-19: "startup times and time to first interaction".

## Marks

`LaunchMarks` (CmuxMobileDesign) takes each mark once per process, in ms since the kernel started
the process, as a signpost (`dev.cmux.mobile`, category `launch`) and a `timing launch <mark>`
log line. Every build has them; their cost is a fixed set of names taken once.

| Mark | When |
|---|---|
| `app_init` | the App's `init` began (dyld, static initializers and UIKit before it) |
| `first_frame` | the first SwiftUI frame (the launch mark) was presented |
| `shell_frame` | the signed-in shell's first frame was presented |
| `workspaces_list_frame` | the Workspaces list's first frame with a row was presented (with the list rig, a seeded `ws-sN` row) |
| `workspace_row_tap` | a workspace row was tapped |
| `chat_composer_ready` | the first frame with an agent chat's composer shown was presented (not a chat face parked behind a terminal) |
| `chat_first_row_frame` | the first frame with a readable transcript row in the agent chat was presented |
| `terminal_ready` | a terminal attached to its session presented a frame |
| `terminal_first_row_frame` | the first frame with non-empty real terminal output was presented |
| `terminal_key_sent` | the first single printable key typed into a terminal was accepted by its session |
| `terminal_echo_presented` | that key's byte, as text in the same terminal's output (not in an escape sequence), was presented |

## Bench

`UITests/LaunchTTIUITests.swift`, in mock mode with 150 workspaces (the list rig). Flows: chat open
(tap `ws-s0`, an agent waiting on the person, to its composer) and terminal input (tap `ws-s2`, a
terminal, type one key, to its echo on screen). `tti_ms` = launch to the list's first frame + tap
to ready (+ key to echo for the terminal): the app's own spans, not the test runner's delays.

- Warm (`LaunchTTIUITests`): terminate and launch, 10 per flow.
- Cold (`LaunchTTIColdUITests`): one launch per fresh simulator boot, 10 boots per flow.

```bash
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
  --arg test --arg ui=LaunchTTIUITests,LaunchTTIColdUITests --artifact artifacts/ios-sim/evidence.zip
```

`SUMMARY.md` gets one line per flow and phase (p50, min-max); `launch-tti.jsonl` has every run.
Add `--arg profile` for an Instruments Time Profiler trace of the same runs.

### Cold live rows

`LaunchColdLiveUITests` uses the paired live daemon and requires the test runner to provide
`CMUX_MOBILE_UI_CHAT_WORKSPACE` and `CMUX_MOBILE_UI_TERMINAL_WORKSPACE`. It prints one
`LAUNCHCOLDLIVE` row per fresh simulator boot, including `first_frame`,
`chat_first_row_frame`, or `terminal_first_row_frame`. Run one or more link profiles and host-load
profiles with repeatable arguments. `duress=off` with `net=` uses the existing `cmux-duress` idle
replay with that `cmux-fault` link profile, while a named duress preset keeps its host load and
overrides its link profile.

```bash
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
  --arg test --arg ui=LaunchColdLiveUITests --arg net=lte --arg net=lossy-3 \
  --arg duress=off --arg duress=duress --artifact artifacts/ios-sim/evidence.zip
```

Each sample is retained under `ui-cold/`; `SUMMARY.md` reports p50/p90 by link, load, flow, and
mark. The simulator script changes take effect only after this script lands on the base branch.

Limits: the terminal is the mock session (no Mac, no network): the network half of a real
first key is the link's, timed by `ConnectTimeline` (`timing launch ...` steps). A simulator
reboot does not empty the host's file cache, so "cold" is a cold process and simulator, not a
cold disk.

### Shaped and loaded cold runs (`net=`, `duress=`)

`cmux-next-ios-sim.sh test ui=SUITE net=lte|lossy-3|off duress=off|PRESET` runs a cold suite (`*ColdUITests`, or `LaunchColdLiveUITests`, 20 runs by default) once per link × load pair. `net=` with `duress=off` is a shaped, otherwise idle, `cmux-duress` replay (`idle,link=PROFILE`); with a preset, the preset's load is kept and its link replaced. Each run's logs go to `ui-cold/<load>+<net>-<test>-<run>`; `LAUNCHCOLDLIVE` rows are summarised p50/p90 per link, load and flow in SUMMARY.md. Limits, also printed there: the terminal flow is the mock session (no Mac, no network), and cold means a cold process and freshly booted simulator, not a cold disk.

### Opens inside a running app (`OpenMarks`, `LaunchTTIOpenPathsUITests`)

`LaunchMarks` takes each mark once per process, so it times a launch's first open only. `OpenMarks` (DEBUG,
`CMUX_MOBILE_LAUNCH_MARKS=1`, label `debug.open-marks`) repeats: each open starts a cycle at its trigger
(`workspace_row_tap`, `deep_link`, `notification_tap`) and takes `route_opened`, `chat_composer_ready` and
`terminal_ready` once per cycle, in ms since the trigger. `LaunchTTIOpenPathsUITests` uses it for the optimum
ledger's session switch, deep link and notification tap rows, and TabsKit's zoom frame log (`firstFrameMs`) for tab
switch. Each metric prints `OPENPATH {"metric":...,"n":...,"p50":...,"p95":...,"misses":...}`; run it with
`--arg duress=off --arg duress=heavy` for the idle and loaded rows from one build.
