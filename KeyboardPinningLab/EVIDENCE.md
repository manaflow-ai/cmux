# Verification

Source reference: `ScreenRecording_08-07-2026 19-50-56_1.MP4`, 1320×2868, 60 fps, 51.62 seconds.

Invariant: during interrupted rapid keyboard show and hide cycles, the Shortcut bar and Composer bar remain one rigid dock. The dock bottom stays coincident with the keyboard top, with no transient gap, overlap, lag, or snap-back.

Scenario: iPhone 17 Pro Max simulator on iOS 26.5, dark appearance, keyboard initially shown, 20 first-responder reversals at 135 ms intervals, then a final focused state. This interval is shorter than a normal keyboard transition and forces animation interruption.

Result: the live layout diagnostic remained `PIN GAP 0.0 pt`. The final run was sampled at 15 fps, including steady, partial-hide, hidden, partial-show, reversed, and final frames. The invariant held in every sampled frame.

Durable evidence is stored at `cmux-assets/feat-keyboard-pinning-lab/rapid-toggle-final/` in the cmuxterm-hq checkout. The directory contains the raw recording, annotated frames, contact sheet, and manifest with the success criterion.
