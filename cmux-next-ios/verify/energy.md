# Battery and memory: the iOS energy bench

Leo, 2026-11-14: "I want us to also look at if we can decrease battery drain/ram on iOS app".

One harness for every battery or memory number the iPhone app's PRs quote: the `energy` mode of
`scripts/ci/cmux-next-ios-sim.sh`, on a fleet simulator mini, base and head built and measured in
the same run on the same simulator.

    cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref HEAD_SHA \
      --arg energy --arg base=BASE_SHA --artifact artifacts/ios-sim/evidence.zip

`--arg cases=idle-home,stream-chat`, `--arg seconds=60` and `--arg reps=3` narrow or lengthen it;
`cases=drift-30m` is the 30-minute idle run (memory at its start and end), left out by default.

## What a case does

Each case installs that side's Demo build fresh, launches it in mock mode
(`CMUX_MOBILE_MOCK_AUTH=1`) on a list rig screen (`CMUX_MOBILE_LIST_SCREEN`, `ListStressRig`),
waits 12 s for the screen to open and settle, then samples the app's process once a second with
macOS `top -stats pid,cpu,idlew,power,mem` (the simulator's app is a process of the Mac).

| Case | Screen | What the app does while sampled |
| --- | --- | --- |
| `idle-home` | Home, 20 rows | holds the screen, foreground |
| `idle-home-5000` | Home, 5,000 rows | holds the screen, foreground |
| `idle-chat-400` | a chat with 400 replayed turns | holds the screen (one long chat) |
| `tabs-10` | a workspace with 10 agent tabs, grid shown | holds the screen (many sessions) |
| `scroll-chat-200` | a chat with 200 turns | the rig scrolls it top to bottom and back |
| `stream-chat` | a chat with 40 turns | one long answer streams |
| `background-home` | Home, 20 rows | Settings in front: the app is in the background |
| `drift-30m` | Home, 20 rows | 30 minutes idle, foreground |

## The columns

- **CPU %**: mean over the samples (100 is one core).
- **Idle wakeups/s**: times a second the process woke a sleeping CPU (timers, polls, run loop
  sources): the number that drains a phone left on a screen. `energy_summary.py` reads top's
  IDLEW either way top prints it (per interval, or a count since launch) and says which in the JSON.
- **POWER**: top's energy impact, the Activity Monitor number (a weighted mix of CPU and wakeups).
- **MEM**: the process's memory footprint at the first and last sample, and its peak.

## Limits

A simulator runs on the Mac's CPU, so the numbers are not an iPhone's milliwatts; compare a base
and a head of one run, never numbers from two runs. Mock mode has no link, so the link's own
keepalives are not in these numbers: they are counted from the Rust link's settings and its tests.
Numbers are from the Demo build (optimized, with the DEBUG developer surface the rig needs).
