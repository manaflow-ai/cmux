# Offline duress simulator for the iPhone app

Leo, 2026-11-22 08:05Z: "we should almost always be doing this. always. testing under duress. you should
also be able to simulate duress "offline" aka without a true agent thing, just like how i introduced that
stuff in the gui."

The GUI's offline simulator is `webviews/scripts/chat-sim.ts` (replays a recorded acpmux chat through the
pane's real reducer on virtual time). This is the iPhone's: no agent, no Mac, no network. A recorded Claude
Code PTY stream and a recorded chat are expanded into a load and replayed into the app while any existing
UI bench runs, so every bench can be read idle and under duress from the same harness.

## Pieces

- **`cmux-tui/crates/cmux-duress`** (Rust, the logic). `cmux-duress gen --preset NAME [--knob value ...]
  --out DIR` resolves the knobs and writes the replay files. Inputs (defaults):
  - PTY: `cmux-tui/crates/cmux-agent-cli-render/tests/fixtures/claude-code-2.1.310/pty.jsonl`
    (a real Claude Code 2.1.310 session, `{"t_ms","b64"}` lines).
  - Chat: `webviews/test/fixtures/chat-sim/replay-lane-session.ndjson` (chat-sim's own fixture: acpmux
    `EventRecord`s with thought/message chunks, tool calls and subagents).
- **`MobileDuress`** (Swift, DEBUG only, a reader): reads `DIR`, runs the CPU load, feeds the terminal
  bytes and the chat records into the app's existing mock paths. No timing or shaping logic lives in Swift:
  every delivery time is in the files.
- **`scripts/ci/cmux-next-ios-sim.sh` `duress=SPEC`**: on the fleet host, runs `cmux-duress gen`, then
  writes the output folder's path into the simulator's global defaults
  (`simctl spawn UDID defaults write -g CmuxMobileDuress DIR`) before any test launches the app. A simulator
  app reads host files, and `UserDefaults.standard` reads the global domain, so every UI bench (including
  ones on other branches) runs under duress with no change to the bench.

## Knobs (one place: `cmux-duress`'s `Knobs`, `duress.json`)

| Knob | Meaning | `idle` | `duress` | `heavy` |
|---|---|---|---|---|
| `history_rows` | styled scrollback rows fed to each terminal before the bench starts | 0 | 10000 | 100000 |
| `stream_kbps` | terminal bytes per second still streaming during the bench (Claude Code redraws) | 0 | 256 | 2048 |
| `panes` | terminals fed at once (the visible one plus hidden ones) | 1 | 4 | 8 |
| `workspaces` | workspaces the mock list holds | 20 | 150 | 500 |
| `chat_records` | acpmux records the chat replays (looped from the fixture, seq renumbered) | 0 | 3561 | 20000 |
| `chat_rate` | records a second while the bench runs | 0 | 40 | 200 |
| `link` | `cmux-fault` link profile (`link-profiles.json`, the Shaper's) shaping every delivery time | none | `lte` | `lossy-3` |
| `cpu_threads` / `cpu_duty` | busy threads in the app process and the fraction of each 10 ms they spin | 0 / 0 | 2 / 0.5 | 4 / 0.8 |
| `seed` | every draw (jitter, loss, synthesized text) | 1 | 1 | 1 |

`duress=heavy,link=2g-trickle,cpu_threads=6` overrides one knob of a preset.

## Files (`DIR`)

- `duress.json`: the resolved knobs, input paths and their SHA-256, and counts (`history_bytes`,
  `stream_chunks`, `chat_records`).
- `pty-history.bin`: raw bytes, fed in one go before the bench (`history_rows` rows of Claude-Code-styled
  transcript: SGR 256-color, bullets, tool results, diffs).
- `pty-stream.jsonl`: `{"t_ms": N, "b64": "..."}`, `t_ms` relative to the stream's start, already shaped by
  the link (serialization at `down_kbit`, `rtt/2` plus seeded jitter, a lost segment held one RTO); the
  reader loops it.
- `chat.ndjson`: acpmux `EventRecord`s, `at` rewritten to the relative delivery ms (shaped the same way).

## Readout

Each bench keeps its own numbers (frame p50/p95/max, hitches, main-thread stalls, TTI, key echo).
`MobileDuress` adds one `[duress]` log line a second (bytes and records delivered, CPU load achieved) and
a `debug.duress` accessibility label, so the summary can show the load actually applied.
