# Real-user stress loop

The iPhone app driven as a person uses it, while the paired Mac's load grows: more workspaces every
cycle, each with one Codex agent (alternating a terminal agent, the Codex CLI in a terminal tab, and a
GUI agent, a Codex agent chat), and Feed events posted all the time. Each cycle walks every path in
`stress.py` `PATHS` with a screen recording and judges it (screen came up, time, hang, crash), while a
sampler records the phone app's and the Mac app's CPU and memory.

- `stress.py`: the loop (on top of `verify/e2e`'s rig: a hidden tagged Mac app and a headless simulator).
- `fleet-step.sh`: one run as a fleet step, from a Mac build job and an iPhone build step.
- `render_report.py`: the run folder as one self-contained HTML log.

```sh
cmux-ci run --class simulator --script cmux-next-ios/verify/stress/fleet-step.sh --ref SHA \
  --arg mac_job=JOB --arg ios_job=JOB --arg cycles=4 --artifact artifacts/stress/evidence.zip --timeout 7200
```

Only Codex agents are started. Codex reaches its model through the worker's subrouter config.
