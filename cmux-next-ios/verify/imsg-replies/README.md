# Inline replies: Chief against Messages

Rig for comparing cmux Chief's inline replies with Apple Messages. Runs on
aws-m4pro-2 (iOS 27.0 simulator runtime, AXe) from `~/imsgreply/`.

## References

- **Transcript drawing** (quote pill, "N Replies", connector line, spacing):
  a real iPhone 17 Pro Max screenshot of Messages (iOS 27, 1320x2868), and
  since 2026-11-03 the simulator's own Messages with `ThreadLinks.m`
  injected next to `ReplyOn.dylib` (below). On its own the stub chat
  (`CKIMSimulatedChat`) never links a sent reply to the message it quotes.
- **Thread rules in the transcript** (`ThreadLinks.m`): the stub drops the
  `threadIdentifier` of a sent reply, colors its quote as SMS (color type 0)
  and keeps no reply counts. `ThreadLinks.m` gives each sent reply back its
  thread (and the copy the other simulated chat receives), colors quotes with
  ChatKit's reply types (9 gray for theirs, 10 blue for mine), counts the
  replies it knows, and opens Messages' inline reply view for a bubble on a
  Darwin notification (`com.cmux.imsghook.reply`, target text in
  `/tmp/imsg-parity/hook/target.txt`), so no Reply menu or swipe is needed.
  `REPLYON_FORCE_CONTEXT=1` brings back ReplyOn's old forcing of a quote onto
  every reply; without it ChatKit decides, which is how the rules below were
  found. `threads/` holds the scenarios (`scen2.py` adjacent, second reply,
  long and reply-to-reply; `scen3.py` reply to a reply, dark, XXL;
  `scen4.py` a thread with both senders), driven by `threadsim.py` (AXe).
  Reply counts are stamped when ChatKit builds a quote's items, so a later
  reply leaves an earlier quote's "N Replies" stale in the stub.
  `devseed.sh` seeds the same conversation into conversation-sim's `empty`
  chat. `m3.py` measures each reply row relative to its quote's top, on
  either capture.
- **Reply mode** (menu, swipe, thread overlay, send):
  Messages on a throwaway iOS 27 simulator with `ReplyOn.dylib` injected
  (`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`). It turns on ChatKit's reply gates
  and resolves the stub's thread originators. Build it with `mkdylib.sh`.
  The `REPLYON_*` environment switches dump ChatKit classes, methods,
  `CKUIBehavior` metrics and `CKUITheme` colors to the unified log.

## Driving

- `sims.sh` creates the paired simulators and turns autocorrect off.
- `pair.sh` holds the shared helpers.
- `GestureServerUITests.swift` is a file-command XCUITest server. AXe drags
  never reach pan recognizers on the iOS 27 simulator, and AXe typing hides
  the software keyboard.
- `scenarios.sh` lists every reply-mode scenario. `runbg.sh` runs them
  detached from your session.

## ChatKit values used

`replyLineWidth` 4, `replyLineBracketRadius` 21, `replyLineViewMaxWidth` 36,
`selfReplyTranscriptSpace` 24, `replyLineColor` black 8 % / white 16 %,
reply preview gray (outline 20 %/22 %, text 44 %), reply preview blue
(outline 40 %/42 %, text 80 %), `replyBalloonTextFont` caption2.

## Thread rules (iOS 27.0, simulator Messages with ThreadLinks)

- A reply right under the message it answers gets no quote and no line; it
  starts its own run (the message above keeps its tail), with the run gap only.
- Otherwise the first reply of a block shows the quote of the thread's root,
  with "N Replies" under it from one reply on ("1 Reply").
- Each reply of the same thread right under it joins the block: no quote,
  no `selfReplyTranscriptSpace` between them (10 pt across senders, the
  contiguous 4 pt within a run), and the line runs on from the quote past my
  replies to the block's last one. It stops above a reply of theirs (7 pt)
  and starts again level with the next bubble's top, 10 pt under theirs.
- A reply to a reply joins the root's thread and quotes the root; a reply to
  any message of the block (or to one the block answers) joins it.
- A plain message, another thread or a timestamp section ends the block.
- "N Replies" is caption2 semibold (as "Delivered"), 7.33 pt under the quote.
  Under a quote of mine it ends 12 pt inside the quote's edge; under a quote
  of theirs it starts 12 pt right of the line, and the line passes beside it,
  its ink 6.33 pt under the quote; my reply starts 11 pt under its glyphs.
- Simulator captures for these rules: `threads/scen5.py` (thread blocks with
  both senders), `threads/scen3.py` (reply to a reply), `threads/scen7.py`
  (a recorded reply joining a block); `threads/seed5.sh` and `seed3.sh` seed
  the same conversations into conversation-sim for Chief.
- The quote outline is 27.33 pt tall in the simulator and 29.33 pt on the
  2026-10-30 device screenshot; Chief keeps the device's.
