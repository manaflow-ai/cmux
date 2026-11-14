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
and waits for the rig to say the screen is ready in its log (`dev.cmux.mobile`, category
`frames`, read with `simctl spawn log stream`): `FRAMELOG list-stress holding SCREEN` for a
still (`LIST_PASSES=0`: the idle, stream and background cases, logged once the screen has opened
and settled, so a stream is already running), `FRAMELOG list-stress SCREEN scroll=` for the
scroll case (its passes begin). It waits up to 180 s and says how long it took
(`RUN: ready N s after launch`); a run with no line is not sampled and fails the step. A fixed
wait sampled a host at load 52 before its chat had opened.

Then it reads the app's process (the simulator's app is a process of the Mac) once a second for
the window with `proc_pid_rusage` (`energy_rusage.py`; no root for a process of the step's own
user), and runs `top` beside it as a cross-check of CPU (`top_cpu_pct` in the run's JSON).

| Case | Screen | What the app does while sampled |
| --- | --- | --- |
| `idle-home` | Home, 20 rows | holds the screen, foreground |
| `idle-home-5000` | Home, 5,000 rows | holds the screen, foreground |
| `idle-chat-400` | a chat with 400 replayed turns | holds the screen (one long chat) |
| `tabs-10` | a workspace with 10 tabs (agents, terminals and browsers in turn), grid shown | holds the screen (many sessions) |
| `scroll-chat-200` | a chat with 200 turns | the rig scrolls it top to bottom and back |
| `stream-chat` | a chat with 40 turns | one long answer streams |
| `background-home` | Home, 20 rows | Settings in front: the app is in the background |
| `drift-30m` | Home, 20 rows | 30 minutes idle, foreground |

## The columns

Every rate is a counter's growth over the window, (last - first) / seconds
(`energy_summary.py`):

- **CPU %**: user + system CPU time over wall time (100 is one core).
- **Wakeups/s**: `ri_interrupt_wkups`, times a second the process was woken by an interrupt
  (timers, polls, run loop sources): the number that drains a phone left on a screen.
- **Energy mW**: `ri_energy_nj`, the kernel's energy estimate for the process in nanojoules,
  per second, in milliwatts (`ri_billed_energy` when that does not move; `energy_source` in the
  JSON says which). It is the Mac's estimate for the simulator's process, not an iPhone's.
- **MEM**: `ri_phys_footprint`, the footprint Xcode's gauge shows, at the first and last
  reading, and its peak.

### Why not top

The first version sampled `top -stats pid,cpu,idlew,power,mem`. On the fleet minis (Apple
silicon) IDLEW read 0 in every case, streaming included: it reports package idle exits
(`ri_pkg_idle_wkups`), which stay 0 for the simulator's app there. And POWER repeated CPU %. Interrupt
wakeups and `ri_energy_nj` are the counters that move.

### The probe

The head's first rep of each case runs `energy_probe` after its window: one 10 to 12 s window
read by `ps`, `proc_pid_rusage`, `top` and an `xctrace record --template 'Activity Monitor'`
(attached, else all processes), with the xctrace process table rows for the app. It prints to
the step log and keeps `energy/probe-RUN/`, so the methods can be compared on the same window.

## Limits

A simulator runs on the Mac's CPU, so the numbers are not an iPhone's milliwatts; compare a base
and a head of one run, never numbers from two runs. Mock mode has no link, so the link's own
keepalives are not in these numbers: they are counted from the Rust link's settings and its tests.
Numbers are from the Demo build (optimized, with the DEBUG developer surface the rig needs).
