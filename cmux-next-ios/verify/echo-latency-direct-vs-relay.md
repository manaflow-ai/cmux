# Keystroke-to-echo: direct vs relay, p50 / p95 / p99

The phone-to-Mac link should feel like messaging: a typed key echoes at the
path's round trip, and the tail (p95, p99) stays close to it. This page reports
keystroke-to-echo p50 / p95 / p99 / max over the direct path and over the
relay (TURN) path, each measured by the same harness, workload and clock.

There are two harnesses, and both run direct then relay in one invocation:

- `cmux-mobile-lanebench --paths direct,relay` drives a real Mac running the
  app, through real signaling and TURN. Use it for device numbers.
- The `echo_latency_bench` example needs no rig. It runs a real WireGuard
  link in one process, with fake signaling, a loopback TURN server and a
  shaped path. Use it in CI and on a lane VM.

## What is measured

The workload follows the app. The phone types one key at a time on the
input-lane `daemon` channel (`send`). Two times are taken:

- `echo_ms`: from the keystroke until the terminal's echo arrives. The echo
  is terminal output on the attach channel, on the main stream.
- `ack_ms`: until the `send` reply arrives on the input lane.

With a flood, a second terminal streams output on the main stream for the
whole run, so the echo has to share that stream with it.

Each path's summary is n / min / p50 / p90 / p95 / p99 / max, by nearest
rank. Times are in ms.

## Real device run

On the Mac, run cmux NEXT signed in, with Settings > Mobile > Allow iPhone
connections on. Then run the phone side from any machine signed in to the
same account. `cmux-mobile-lanebench` uses the same link code as the app
and drives the Mac's real daemon the way the app does. The token goes in a
0600 file and is never printed.

```bash
cd cmux-next-ios/rust
cargo build --release -p cmux-mobile-host --bin cmux-mobile-lanebench
target/release/cmux-mobile-lanebench \
  --base-url <backend origin> --token-file <token file> \
  --team <team> --mac <mac device id> --transport wireguard --exclude-cgnat \
  --paths direct,relay --samples 300 --interval-ms 250 \
  --flood "perl -e '\$|=1; for(1..400000){print \"y\" x 999, \"\\n\"; select(undef,undef,undef,0.0005)}'"
```

- **Output.** One JSON line per path goes to stdout. Each line carries
  `requested_path`, the link's actual `path`, `echo_ms`, `ack_ms`,
  `idle_echo_ms`, `missed` and `flood_mbps_received`. A table goes to
  stderr.
- **Paths.** `direct` dials as the app does: direct preferred, with TURN
  offered. `relay` dials with `--relay-only`, so only TURN is used. If
  `path` says the direct run fell back to the relay, the direct row is not
  valid.
- **Flood.** The flood is rate limited, about 10 Mbit/s. An unthrottled
  `yes` makes the Mac's terminal drop the PTY (terminal-input-lane.md). It
  must outlast the samples: 300 keys at 250 ms take about 80 s. Pass
  `--flood ''` to type with no flood.
- **WebRTC.** Pass `--transport webrtc` to measure the WebRTC transport.
- **Older flags.** Without `--paths`, the bench runs one dial, as
  `--relay-only` and `--block-udp` say, and prints one JSON line.
  `--samples` now defaults to 200.

## In-process run (no rig)

```bash
cd cmux-next-ios/rust
cargo run --release -p cmux-mobile-link --example echo_latency_bench -- \
  --paths direct,relay --samples 300 --lan-rtt 2 --relay-rtt 40 \
  [--interval 50] [--jitter MS] [--loss PCT] [--flood-mbps M]
```

How the path is shaped: each side delays every datagram it receives by half
the round trip of its path, LAN or relay. It then adds uniform jitter up to
`--jitter` ms, and drops each datagram with probability `--loss` percent.
The `direct` row has no TURN server. The `relay` row is relay-only on both
sides. The first 10 keys are warmup and are not counted (`--warmup`).

### Results (2026-11-21)

Run on a lane VM (Linux, 32 cores), release build, `--samples 300 --interval
50`, LAN 2 ms and relay 40 ms round trip. Every run ended on the requested
path, the input lane was `Ready`, and no key was missed. Each cell is
p50 / p95 / p99 / max in ms.

| Shaping | Path | Echo | `send` ack | Flood received |
| --- | --- | --- | --- | --- |
| none | direct | 4.76 / 5.02 / 6.89 / 14.9 | 4.72 / 5.00 / 6.86 / 14.9 | - |
| none | relay | 44.2 / 55.8 / 81.1 / 96.3 | 44.2 / 55.7 / 81.0 / 96.2 | - |
| 5 ms jitter, 1% loss | direct | 7.74 / 11.1 / 14.7 / 16.0 | 7.81 / 11.3 / 14.6 / 16.6 | - |
| 5 ms jitter, 1% loss | relay | 45.8 / 50.0 / 53.7 / 72.8 | 45.8 / 50.6 / 54.0 / 72.9 | - |
| 20 Mbit/s flood | direct | 4.62 / 6.12 / 9.46 / 26.7 | 4.29 / 5.31 / 8.20 / 26.5 | 19.8 Mbit/s |
| 20 Mbit/s flood | relay | 42.8 / 45.0 / 46.3 / 105 | 42.4 / 43.9 / 44.8 / 48.3 | 20.2 Mbit/s |
| jitter, loss, 2 Mbit/s flood | direct | 10.1 / 19.1 / 23.4 / 31.5 | 6.77 / 9.85 / 11.1 / 11.9 | 2.0 Mbit/s |
| jitter, loss, 2 Mbit/s flood | relay | 46.3 / 53.5 / 57.3 / 122 | 44.9 / 47.9 / 49.4 / 56.2 | 2.0 Mbit/s |
| jitter, loss, 20 Mbit/s flood | direct | **526 / 571 / 591 / 765** | 6.53 / 8.99 / 10.2 / 10.8 | 12.9 Mbit/s |
| jitter, loss, 20 Mbit/s flood | relay | **1630 / 2087 / 2446 / 2496** | 44.9 / 49.3 / 72.1 / 75.1 | 4.0 Mbit/s |

### Findings

- **Fixed overhead.** On a clean path, echo costs about 2.7 ms over the
  shaped round trip on direct (4.8 ms at 2 ms RTT) and about 4 ms on relay
  (44 ms at 40 ms RTT). The relay's tail is wide even with no loss: p99 is
  81 ms, twice the RTT. Both are worth profiling: the userspace tunnel's
  timer and polling, and the relayed hop.
- **The input lane works.** The `send` ack stays at the path RTT in every
  case, including when the main stream is saturated.
- **The echo is the weak point.** It still rides the main stream. When a
  flood asks for more than the lossy path can carry (12.9 Mbit/s direct and
  4.0 Mbit/s relay at 1% loss), the main stream's queues fill. Echo then
  waits behind them: 0.5 s at p50 direct, 1.6 to 2.4 s relay. This is the
  same effect the real-device run in terminal-input-lane.md saw on
  WireGuard over TURN: p90 echo of 1.1 s. A messaging-grade echo needs the
  focused terminal's output ahead of other bulk output, or flood output
  paced to what the path carries.

Raw JSON lines from these runs were in `/tmp/olb/*.jsonl` and are not
committed.
