# Chief latency harness

The one before/after harness of the Chief latency lane: every PR that changes how fast or how large a Chief turn is
cites its table. It reads the same trace fields as Lucas's measurement of a live Chief (the shared plan "Chief turns
are slow and large", 2026-11-23): `turn.start` (sources, `layout.delta.rendered`, view and system bytes),
`turn.end` (`first_usage`, `usage`, `requests`, `ttft_ms`, `ms`, `cost_usd`), `request` and `tool`.

## What it runs

`scripts/measure/chief-latency.sh` on one fleet Mac, alone on the worker:

1. Builds acpmux, optchat-chief and cmux-tui at `before` and at `after`, each in its own worktree of that commit
   (cmux-tui from the published tree when there is one).
2. Downloads Claude Code at a pinned version, checked against the release manifest, into a fresh HOME.
3. For each round, runs `chief_driver.py --scenario latency` on a new scratch Chief at `before`, then at `after`
   (the order alternates by round). The driver and this analysis come from the harness checkout, so both sides are
   measured the same way; only the binaries differ. The model is real: Claude through SR2, which signs requests
   itself, so no credential reaches the worker.
4. `chief_latency.py summary` pools each side's rounds, and `chief_latency.py compare` prints the table.

The `latency` scenario (`scenario.py`, `latency_turns`) is 15 asks, one of each kind the plan names: a trivial
reply, a fact to remember and its recall (twice, once after a view rebuild), arithmetic, a reply over 45 words, a
tool call over a file, one subagent with a follow-up while it runs, a paste over 32 KB that makes the host freeze a
new view (`DELTA_HARD`) and the turn after it, two parallel subagents and their reports arriving, a status
question and a close.

## Numbers

| Number | From |
|---|---|
| Input tokens of a turn's first request (p50, p90) and of every request (p50) | input + cache read + cache write |
| Requests per Chief turn | `turn.end.requests` |
| First token (all, warm, cold turns) | `turn.end.ttft_ms` |
| Turn time p50, p90 | `turn.end.ms` |
| Send to first and last reply, as the person sees it | the driver's clock (`turns.json`) |
| Cold share | turns whose first request wrote more to the cache than it read |
| Host-started turns, view re-renders (cold ones), refused sends | `sources`, `layout.delta.rendered`, `tool` events with `ok: false` |
| Cost | `turn.end.cost_usd`, API-equivalent |

## Run it for a pair of refs

```sh
cmux-ci run --class exclusive --measurement --label measure \
  --script scripts/measure/chief-latency.sh --ref HARNESS_SHA \
  --arg=base_url=http://100.120.48.119:4016 \
  --arg=before=BASE_SHA --arg=after=HEAD_SHA --timeout 10800
```

- `HARNESS_SHA` is a commit that has this harness (feat-cmux-next once it lands, or your PR head).
- `before` and `after` are full 40-character SHAs. Leave out `after` for one ref's numbers. `after` equal to
  `before` is an A/A run, which shows the harness's noise.
- Optional: `rounds=N` (1-9, default 1, about 20 minutes per side), `model=`, `effort=`, `only=l01,l06`,
  `claude=X.Y.Z`, and `env=OPTCHAT_*|CHIEF_*|MUX_*=VALUE` for the host on both sides (an A/B of one switch at one
  ref).

The log ends with the markdown table. Paste it under "Before/after" in the PR body. Through the bench registry:

```sh
scripts/bench/cmux-bench chief-latency --host fleet --arg ref=HARNESS_SHA --arg before=BASE_SHA --arg after=HEAD_SHA
```

To redo the table from a log or from run dirs you have:

```sh
python3 Native/OptChat/optchat-chief/measure/chief_latency.py summary RUN_DIR [RUN_DIR...] --ref SHA --out side.json --md side.md
python3 Native/OptChat/optchat-chief/measure/chief_latency.py compare before.json after.json --md table.md
```

The numbers have the noise of a real model. Compare sides from one run, never across runs or workers. Use
`rounds=3` when a change is under about 15%.
