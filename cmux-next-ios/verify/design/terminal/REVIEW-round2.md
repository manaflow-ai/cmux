# Terminal and tabs: round 2 designer review

Fresh designer, 2026-10-14, against [SPEC.md](SPEC.md) and the round 1 fix
list in [REVIEW-round1.md](REVIEW-round1.md). Build under review:
`origin/feat-cnx-ios` at `b46269e4` (round 2: `c9aa0362` R1-0, `0c8f326f`
R1-1 to R1-8, `96d2af88` TUI sizing and rig paging). The designer writes no
app code. Every item was re-checked with this review's own captures; earlier
passes and the implementer's notes were not taken as evidence.

**Verdict: NOT signed off.** All eight round 1 items now pass in the state
they were written for, and the rig is fully green. But the TUI sizing trade-off
that came with R1-1 has a visible defect (R2-1, major): after quitting `top`
with the keyboard up, the shell's earlier output is pushed above the screen,
about 300 pt of blank sits under the prompt, and you cannot scroll it back
until the keyboard goes down. Also, Paste in the attachment menu is offered for
a file URL but does not attach the file (R2-2). The rest of the list is polish.

## How this was captured

- **Live.** E2E rig from this worktree, Demo build of `b46269e4`, iOS 26.5,
  iPhone 17 Pro (402 × 874 pt), simulator `cmux-mobile-term-review2`, against the
  hidden cmux-next DEBUG Mac build `cmux-mobile-e2e-604fc689` (same as round 1). Two
  invocations with `--keep --latency none`, started from `fresh_install`:
  `065725-ios26` (fresh_install to relaunch_restore, **9/9 pass**) and
  `070023-ios26` (term_direct, term_composer, term_keys, term_tui,
  term_scrollback, files_links, background, **7/7 pass**). Results:
  `round2-review/rig-*-results.json`, screenshots `round2-review/rig-*.jpg`.
  Then manual checks on the same session with `axe` taps and drags; text only
  through the soft keyboard, no hardware key events. Mac-side rows read with
  `cmux terminal list` / `screen read` on the rig socket.
- **Mock.** Debug build (`-derivedDataPath /tmp/cmux-mobile-term-review2-dd`) installed
  on the same simulator, launched with `-cmuxMobile.dev.mockData YES` ("mock (layout
  only)"), after the live checks.
- **Load.** Recordings were made at 1-minute load 20.3 (`v1`), 16.2 (`v2`) and
  13.2 (`12`'s video). Rig steps ran at load 13 to 104 (the box spiked during
  `term_keys`); rig timings are not used as measurements.
- Measurements in pt (1206 px screenshots ÷ 3), from pixels or `axe`
  accessibility frames. Videos are scaled to 402 px wide.
- Never paired with the user's Mac; no phone. The simulator was deleted and the
  rig Mac app quit at the end.

## Round 1 failures, re-checked

| Item | Result | Evidence | Measurement |
| --- | --- | --- | --- |
| R1-0 relaunch restore attaches | **PASS** | rig `relaunch_restore`, `v1-relaunch-restore.mp4`, `03`, `04` | Rig: tab restored 2.2 s after launch, attached 3.6 s, input ran on the Mac. Own video (cold terminate + launch while the tab was open): launch screen at 3.5 s, last frame shown dimmed at 4.4 s with "Connecting to Aziz's MacBook Pro…", live at 4.6 s, about 1.1 s after the launch screen. No skeleton rows. Defect R2-5 below (stale cached frame ghosts over the live one for one frame). |
| R1-1 TUI resize once after the keyboard settles | **PASS** with polish R2-3 | `v2-top-keyboard-show-hide.mp4`, `05`, `06`, `02` left, rig `tui-top` | `top` with the keyboard up: header row (Processes) on row 0 at 62 pt, PTY 53 × 24 (Mac `terminal list`); keyboard down: 53 × 41. Show: alt screen stays pinned to the composer during the animation (3.4 to 3.7 s), resized once at 3.8 s, no blank frame. Hide: pinned while it falls, then one fully black frame (7.33 s, 33 ms), then 1.1 s with the old 24 rows on top and black below until `top` redraws at 41 rows (8.5 s). |
| R1-1 trade-off: quit `top` with the keyboard up | **FAIL (major, R2-1)** | `01`, `02` middle and right | Mac screen after `q`: 24 rows, cursor row 12, rows 0-7 hold `echo m23878`, its output and `❯ top`. The phone shows Mac row 8 (the post-`top` prompt) at the top inset; rows 0-7 are above the screen, and 320 pt of black sits between the cursor (≈ 135 pt) and the composer (455 pt). A 200 pt pull-down does not reveal them (the terminal's frame moves -1618 → -2002 pt and stays). After the keyboard goes down everything is back in place (`02` right). This is B1 again in that state. |
| R1-2 no readable text around the bottom chrome | **PASS** with polish R2-6 | `08` | Scrolled up 50 rows at rest: below the composer's top edge (≈ 734 pt) nothing is drawn; between and below the toolbar pills (784-874 pt) pixel max is 0 (pure background). Leading corner clean. The row straddling the composer edge is cut hard: its brightness at 728 pt is 93 % of the rows above (no 24 pt fade). Top edge under the status bar fades (row at 44-50 pt drawn at 22 % brightness). |
| R1-3 seam in the key bar at rest | **PASS** | `07-keybar-rest` | Brightness across `tab` at 524 pt is flat at 72 from 168 to 206 pt; no step. Same in mock (`13` right). |
| R1-4 scroller width and cut key | **PASS** with polish R2-4 | `07-keybar-rest`, `07-keybar-after-swipe` | Scroller 165.3-316.0 = 150.7 pt; at rest it holds exactly `tab` (44), `⇧tab` (53.3), `↑` (40), last key ends at 314.7. Gap ^C → scroller 6.0 pt. Trailing fade runs 289 → 316 pt (≈ 26 pt, spec 12), so `↑` is drawn at 30-100 %. After a swipe the scroller snaps to `|` at the leading edge, but a 13 pt sliver of the next key (`-`) shows at the trailing edge. |
| R1-5 row 0 brightness at rest | **PASS** | `11`, `13` left | Live: row 0 glyphs at 64-76 pt, pixel max 690, same as rows 2-10 (690). Mock row 0 equally bright. |
| R1-6 rig `term_keys` | **PASS** | rig `070023` | "^C interrupted sleep; Up Arrow recalled the last command; Left Arrow moved the cursor (abd → abcd); joystick moved the cursor 10 → 2". Next step `term_tui` passed (vim wrote the file), so the cleanup works. |
| R1-7 Files and Links header and naming | **PASS** (minor gap) | `09` | Chips top 482.2 pt; Done button bottom 468.8 (13.4 pt; spec 8, round 1 was 21). Chips start 23.4 pt from the screen, 15.4 pt from the sheet's content edge (list rows start at 8). Title "Files and Links", menu "Files and Links". Counts on every chip ("All 8", "Files 6", "Folders 1", "Code 6", "Links 1"); `.isSelected` on the selected chip in code (`ArtifactsSheet.swift:108`). New defect R2-7 below. |
| R1-8 Paste only for an image or file | **PASS for text; FAIL for a file URL (R2-2)** | `10`, code | Text on the pasteboard (`simctl pbcopy`): menu is Files, Photos, Camera; no Paste. Image: not driven live (the simulator pasteboard can only be set to text without touching the host's); code shows Paste first and the image becomes an attachment chip. File URL: see R2-2. |

## Other SPEC items, spot-checked this round

| Item | Result | Evidence |
| --- | --- | --- |
| B1 top-anchored | PASS | `11`, rig `term_scrollback` ("after clear the first row is at y 65 pt and a short session does not scroll"). Except R2-1. |
| B2 pinned esc / ctrl / ^C | PASS | `07`: esc 10-54, ctrl 60-113, ^C 119-159, always shown with focus. |
| M3 last row above the composer | PASS | `11`, `13`. |
| M4 one key bar rule, mock = live | PASS (soft keyboard) | `13`: mock and live key bar frames identical; hidden at rest in both; mock composer has `+`. Hardware keyboard not driven (same reason as round 1). |
| M7 refused preview | PASS | rig `files-preview`; accessibility id `artifacts.preview.refused`. |
| M8 hidden controls | FAIL, deferred upstream (U3) | AX tree still has `Close e2e-t1` (372, 0, 30 × 30), `Page Menu` (90, 792) and `Reload` (268, 792). |
| P1 page menu | PASS | Files and Links, Paste, Clear, Scroll to Bottom \| Copy Directory \| Close Tab. |
| P5 return from background | PASS | `12`: after 40 s at Home the last frame shows at once (2.25 s), new output at 4.0 s, no mid-screen caption. Rig `background` pass. |
| P6 grid active ring | FAIL, deferred upstream (U1) | Mock grid, no ring. |
| Pending, not decided | — | CmuxTabsKit's ~240 ms grid zoom (user decision). |

## Fix list (round 3)

- **R2-1 (major) After a TUI quits with the keyboard up, the shell must look
  like a shell.** Today the PTY keeps the TUI's 24 rows until the keyboard next
  settles, and the phone shows the 24-row screen bottom-anchored-ish: the
  earlier output is above the top inset, unreachable, with ≈ 320 pt of black
  under the prompt. Either resize the PTY back to the keyboard-down rows when
  the alternate screen ends (and break the reset ping-pong some other way, for
  example by ignoring alt-screen off/on pairs that arrive inside a resize's
  replay), or keep the rows but lay the primary screen out top-anchored with
  scrollback reachable. Check: `top` with the keyboard up, `q`, the `❯ top`
  line and the output before it are visible above the prompt, and a
  pull-down scrolls.
- **R2-2 (major) Paste for a file URL.** `plusMenu` shows Paste first when the
  pasteboard holds `public.file-url`, but `pasteFromClipboard()` has no file
  branch: it attaches only `UIPasteboard.general.image`, else appends
  `UIPasteboard.general.string` to the composer. A copied file therefore either
  does nothing or puts a phone-local `file:///…` path into the shell command,
  which means nothing on the Mac. Read the file URL (security-scoped) and add
  it as a file attachment chip like Files does; otherwise do not offer Paste
  for it. (Code finding; not driven live.)
- **R2-3 One black frame on the keyboard-hide resize.** `06`, 7.33 s: the
  whole terminal is black for one frame when the PTY grows back to 41 rows.
  Keep the last frame until the replay arrives.
- **R2-4 Key bar trailing edge.** Fade 12 pt as specified (today ≈ 26 pt dims
  the last whole key to 30 %), and after a swipe snap so no sliver of a key
  shows (`07-keybar-after-swipe`: 13 pt of `-` at 303-316 pt).
- **R2-5 Stale last frame on relaunch.** The cached frame is older than what
  was on screen at quit (it shows the `ls` output from before `seq 1 300`)
  and for one frame it is drawn over the live frame (`04`, third frame: two
  texts overlap). Save the frame when the app backgrounds, and swap, don't
  blend. The title pill also flashes light grey on that frame.
- **R2-6 Bottom edge.** The row cut by the composer's top is drawn at full
  brightness. Add the 24 pt fade above the composer (as at the top), so a half
  row reads as "more below".
- **R2-7 Files and Links lists a wrapped path fragment.** A path wrapped at the
  terminal's 53 columns (`/tm` + `p/cmux-mobile-e2e-070024-sample.md`) is listed as a
  separate file `p/cmux-mobile-e2e-070024-sample.md` (`09`). Join soft-wrapped rows
  before detecting paths. `/tmp/x` and `/private/tmp/x` also appear as two
  entries; consider resolving them to one.
- **Upstream (unchanged):** M8/U3 hidden Close, Page Menu and Reload; U1 active
  tab ring; U2 card title; U4 thumbnail hook. Pending user decision, not
  decided here: CmuxTabsKit's ~240 ms zoom.

## Not verified

- Image paste end to end, and a file URL on the pasteboard (R2-2 is from the
  code).
- Hardware keyboard key bar; ctrl double-tap lock (two taps < 0.4 s); 120 Hz.
- Image preview at the large detent (P4).

## Artifacts (`round2-review/`)

- `01-after-top-quit-keyboard-up.jpg`: R2-1, after `q` (left) and after a
  200 pt pull-down (right).
- `02-top-kbup-quit-kbdown.jpg`: `top` with the keyboard up, after `q`, after
  the keyboard goes down.
- `03-relaunch-strip.jpg`, `04-relaunch-frames-4.2-5.3s.jpg`,
  `v1-relaunch-restore.mp4`: R1-0 and R2-5.
- `05-top-keyboard-show-frames.jpg`, `06-top-keyboard-hide-frames.jpg`,
  `v2-top-keyboard-show-hide.mp4`: R1-1 and R2-3 (10 fps strips; times from
  the start of the video).
- `07-keybar-rest.jpg`, `07-keybar-after-swipe.jpg`: R1-3, R1-4, R2-4.
- `08-scrolled-up-rest-bottom-chrome.jpg`: R1-2, R2-6.
- `09-files-and-links.jpg`: R1-7, R2-7.
- `10-attach-menu-text-pasteboard.jpg`: R1-8 (text on the pasteboard).
- `11-terminal-rest-row0.jpg`: R1-5.
- `12-return-after-40s-background.jpg`: P5.
- `13-mock-rest-and-keyboard.jpg`: mock (layout only), at rest and keyboard up.
- `rig-065725-*`, `rig-070023-*`: rig screenshots and results.
