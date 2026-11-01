# Inline replies: Chief against Messages

Rig for comparing cmux Chief's inline replies with Apple Messages. Runs on
aws-m4pro-2 (iOS 27.0 simulator runtime, AXe) from `~/imsgreply/`.

## References

- **Transcript drawing** (quote pill, "N Replies", connector line, spacing):
  a real iPhone 17 Pro Max screenshot of Messages (iOS 27, 1320x2868). The
  simulator's Messages can't show these, because its stub chat
  (`CKIMSimulatedChat`) never links a sent reply to the message it quotes.
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
