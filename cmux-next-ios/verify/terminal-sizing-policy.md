# Terminal sizing policy over the real link (2026-10-23/24)

Question: does each **Terminal Size When Shared** policy (PROTOCOL.md "Terminal sizing
policy (host-size-policy-v1)") size a shared Mac terminal from the device it names, with the
Mac and one phone, and with the Mac and two phones, while Claude Code, `htop` and `vim`
run in it? Do the Mac pane and every phone stay legible in each case?

Result: **pass**, with one rendering bug found and fixed during the run (htop below).

## Rig

| Part | What |
| --- | --- |
| Mac | Fleet build `d4d7d953eca95756be16361b`, tag `cmux-mobile-e2e-5d2488da`. Source: `szpol-verify-d2353a1` = PR head `d2353a1eedfc` plus the two base-compile fixes the tip needed (#24679, #24689), with no runtime change to this feature. Debug, hidden on mini-cmux11s (`open -g -j -n`, isolated config, credentials and pairing seed via `open --env`), never activated. Its daemon lists `host-size-policy-v1` and `host-grid-view-v1` |
| Phones | Debug app built on mini-cmux8s (Xcode 26.6) at `d2353a1eedfc`, then again at `f90e7e0065e0` (the htop fix). Two headless simulators: `cmux-szpol-a` (iPhone 17 Pro, a 53×42 grid) and `cmux-szpol-b` (iPhone 16e, 51×41). Simulator.app was never opened |
| Link | Simulators on mini-cmux8s to the Mac on mini-cmux11s, over production signaling and WireGuard. No local socket, loopback or debug shortcut |
| Mac pane | A hidden rig app draws no window, so `verify/scripts/sizing_probe.py` holds a Mac view (`device_kind: mac`, a local connection) of each terminal at 120×39. It samples the PTY grid (`vt-state`) and the size state (`get-size-state`) every 0.25 s, writes the Mac's policy, and types into the Mac pane |
| Programs | Three workspaces on the Mac: `szpol-claude` (a real Claude Code session that answered a 40-line prompt), `szpol-htop` (`htop` on a loaded mini) and `szpol-vim` (`vim` on a file of 120-character lines) |
| Driver | `verify/e2e/sizing_policy.py` (AXe taps and OCR on the simulators, `simctl io recordVideo` for every phone in every cell) |

## Results: policy × devices (phone build `f90e7e0065e0`)

The Mac grid is the PTY grid the probe read once it held steady for 2 s. Each cell covers
all three programs.

| Policy (Mac setting) | Mac + phone A | Mac + phones A and B | Legible on every phone |
| --- | --- | --- | --- |
| Fit the Smallest Viewer (`smallest`) | 53×39 (phone A's columns, the Mac's rows); owners Mac and A | 51×39 (B is narrowest); owners Mac and B | yes: both phones show the whole grid |
| Prefer This Mac (`mac`) | 120×39; owner Mac | 120×39; owner Mac | yes: both phones pan sideways across 120 columns, nothing wraps |
| Prefer the Active Device (`latest`) | A tap on A gives A's grid (53×24, keyboard up); Mac-pane typing gives 120×39 | Tap on A gives A's grid (53×24), tap on B gives B's grid (51×23), Mac typing gives 120×39 | yes |
| Priority Order, `device:A` then `mac` | 53×42; owner A | 53×42; owner A (B pans/letterboxes) | yes |
| Priority Order, `mac` then `device:A` | 120×39; owner Mac | 120×39; owner Mac | yes |

- **Prefer the Active Device.** The driver expected each phone's keyboard-down grid after a
  tap, so it logged these cells as FAIL. The tap shows the software keyboard, and a phone
  showing a full-screen app claims its keyboard-up rows (existing `TerminalTUISizing`). The
  probe log checks the real rule: in all 4195 samples where a phone owned the grid, the grid
  equaled that phone's live claim, with 0 mismatches. The owner moved to the phone on its
  tap and back to the Mac on Mac typing every time. The "Connected Devices item not found"
  note in those cells is the same cause: the keyboard covered the title menu.
- **Connected Devices** (opened from the terminal's title menu) lists every viewer with the
  size it asks for, and names the one that sets the grid. Examples:
  - `smallest`, two phones: "51 × 39, Fits the smallest viewer"; This Mac 120×39 (Sets
    size), This iPhone 53×42, cmux-szpol-b 51×41 (Sets size).
  - `mac`: "120 × 39, Set by This Mac, first in order".
- **The phone sets the Mac's policy.** On the phone, Settings › Terminal › Terminal Size When
  Shared › szpol-rig loaded the Mac's policy (Fit the Smallest Viewer) over the link.
  Choosing **Prefer This Mac** there changed the Mac's daemon to `mac` (`get-host-size-policy`),
  and its terminals went to priority with the Mac first.

## Found and fixed during the run: htop garbled on a grid wider than the phone

With the phone at `d2353a1eedfc`, `htop` at 120 columns came out garbled on the phone under
Prefer This Mac and Priority (Mac first). Rows held fragments of an earlier layout, and ^L did
not clear them (`video/htop-garbled-before-fix-5d2488d.mp4`). Claude Code and vim at the same
width were clean.

Cause: a Mac grid change that arrived while the terminal page was out of its window never
reached Ghostty, because the mirror's size sync returned early without a window. Fixed in
`f90e7e0065e0`, a phone-only change: the mirror tells Ghostty its size out of a window too,
and again when it is back in one.

Re-run on the same rig at `f90e7e0065e0`, with Prefer This Mac:

| Path | Result |
| --- | --- |
| Fresh launch, open htop (Mac 120×39) | clean, aligned columns; a sideways pan shows the rest of the 120 columns |
| Back to the list; while away the Mac pane goes to 100×36; reopen | clean at 100×36 |
| The Mac pane back to 120×39 while open | clean at 120×39 |

The whole one-phone and two-phone matrix above was then re-run on this build: every htop cell passed.

## Not verified

- **A real Mac window.** The Mac pane is the probe's Mac view, a real `device_kind: mac`
  participant on a local connection. The rig app draws no window, so the Mac's own
  rendering of a narrower grid (hatch and chip) is not captured here.
- **Mac Settings › Mobile row.** Its rendering is covered by the settings test
  (`mobileCard.test.tsx`), not by a capture on this rig.
- **Settings file location.** The daemon wrote the phone's choice to
  `~/.config/cmux/cmux-next.json`, not to the rig app's `CMUX_NEXT_CONFIG_FILE`. The app
  launches cmux-tui through `server ensure` without passing that override, so the daemon's
  settings owner reads the default file. This predates this PR (every daemon setting
  behaves the same way under a rig override). The run therefore drove the policy through
  that file and restored it afterward.
- **Keyboard-down grid in Prefer the Active Device.** The tap that makes a phone active
  also raises its keyboard, so the run saw the keyboard-up grid only.

## Evidence

Git-ignored. On mini-cmux8s:

- `~/szpol-verify/matrix-1p-f90e/`, `~/szpol-verify/matrix-2p-f90e/`: `results.json`, `run.log`,
  `shots/`, and one mp4 per phone per cell.
- `~/szpol-verify/htop-f90e7e0/`: the htop re-run.
- `~/szpol-verify/htop-repro/`: the garbled run before the fix.
- `~/szpol-verify/matrix-1p/`: the first pass, at `d2353a1eedfc`.

Compact copy on the laptop that ran it: `/tmp/szpol-evidence/` (`2p/`, `1p-f90e/`, `ui/`,
`video/`, `results-*.json`, `probe.jsonl`).

## How to rerun

```bash
# Mac (mini-cmux11s): fleet build of a pushed SHA, then the hidden rig
cmux-ci build cmux --ref <sha> --tag cmux-mobile-e2e-<sha8> --priority -10
python3 rig.py prepare && python3 rig.py launch      # rig.py: mac.py's Mac, pairing seed names both simulators
python3 verify/scripts/sizing_probe.py --socket <daemon socket> --config ~/.config/cmux/cmux-next.json \
    --setup ~/szpol-verify/work --mac-view 120x39   # prints the three surfaces
# Relay: probe stdout -> samples.jsonl on the simulator host; commands.jsonl -> probe stdin
python3 verify/e2e/sizing_policy.py --app <CmuxMobileApp.app> --phones cmux-szpol-a,cmux-szpol-b \
    --samples samples.jsonl --commands commands.jsonl \
    --workspaces szpol-claude:N,szpol-htop:M,szpol-vim:K --mac-device <hostd device id> --reuse --out <dir>
```
