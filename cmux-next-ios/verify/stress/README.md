# Real-user stress loop

The iPhone app driven as a person uses it, while the paired Mac's load grows: more workspaces every
cycle, each with one Codex agent (alternating a terminal agent, the Codex CLI in a terminal tab, and a
GUI agent, a Codex agent chat), and Feed events posted all the time. Each cycle walks every path in
`stress.py` `PATHS` with a screen recording and judges it (screen came up, time, hang, crash), while a
sampler records the phone app's and the Mac app's CPU and memory.

- `stress.py`: the loop (on top of `verify/e2e`'s rig: a hidden tagged Mac app and a headless simulator).
- `scripts/ci/cmux-next-ios-sim.sh shots stress=...`: one run as a fleet step (builds both apps on the worker).
- `render_report.py`: the run folder as one self-contained HTML log.

```sh
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
  --arg shots --arg stress=cycles:4,start:4,add:4,max:24,feed:4 --artifact artifacts/ios-sim/evidence.zip --timeout 7200
```

Only Codex agents are started. Codex reaches its model through the worker's subrouter config.
