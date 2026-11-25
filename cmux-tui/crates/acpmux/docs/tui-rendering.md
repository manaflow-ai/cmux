# TUI rendering

The UI keeps Ratatui's immediate-mode frame and cell diff. It retains expensive
document layout separately from frames, following the distinction between
[event handling and rendering](https://ratatui.rs/tutorials/counter-async-app/full-async-events/).

The boundaries are:

- `Transcript::layout_dirty_from` records the earliest item affected by updates.
  Duplicate sequence numbers do not invalidate anything. Historical tool and
  permission changes invalidate their actual item; queued promotion can
  invalidate earlier indices.
- `render::TranscriptCache` retains completed turns and rebuilds the mutable
  tail. Markdown within that tail is cached by item and invalidated with the
  model. Width, theme, visibility options and collapses invalidate layout.
  Input, hover, scroll and animation paint only visible rows from this cache.
  Copy and hit-test indexes replace only their changed suffix.
- `FrameSchedule` coalesces changes, limiting output to one frame per 16 ms.
  Keyboard events have priority over daemon traffic. Idle screens do not draw;
  animation and housekeeping use a separate clock that skips missed ticks.
- `AtomicBackend` owns all frame output. OSC 8 hyperlink metadata participates
  in the cell diff, including metadata-only changes and link removal. The
  backend buffers the text, styles and final cursor into one synchronized
  update. No post-frame repaint may write transcript text to stdout.

Direct appends to `Transcript::items` are detected by length. Any new code that
mutates existing items outside the event model must call `invalidate_layout`
with the earliest changed index. A replacement transcript starts dirty.

Run `cargo test` for layout, invalidation, cursor and terminal-output regression
tests. The ignored release benchmark compares rebuilding 500 turns with cached
input frames and streamed updates:

```sh
cargo test --release --lib benchmark_retained_transcript -- --ignored --nocapture
```

The PTY fixture uses a temporary socket and synthetic daemon, with no real
agents or user sessions. It checks idle output, input-only diffs, final cursor
positions and input responsiveness during 1,000 streamed updates:

```sh
cargo build --release
python3 tests/tui_terminal.py target/release/acpmux
```

`--baseline` reports the same latency and output measurements for an older
binary without enforcing the new output invariants. These are synthetic local
measurements, not a guarantee about terminal-emulator or system scheduling time.

## Local measurements

On a 120×40 PTY with 500 turns and syntax-highlighted Rust blocks, the old
installed binary measured 657–796 ms median input latency across two runs.
The new release build measured 21.7 ms, and 21.0 ms while 1,000 token updates
arrived. The fixture verified no hyperlink repaint on typing, zero idle output,
168 coalesced streaming frames, and cursor restoration across resize. The host
was running other workloads, so absolute wall-clock results vary.

The isolated layout benchmark measured 193.7 ms to rebuild all 6,502 rows,
0.0004 ms for an unchanged cached layout, and 0.22 ms for a streamed update.
The cache figures measure document preparation, not full terminal frame time.
