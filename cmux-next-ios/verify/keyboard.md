# Keyboard: composer docking, top clipping, interactive dismissal

Branch `feat-cnx-ios-kbd`, 2026-10-13. This responds to user feedback from a real iPhone 17 Pro Max on iOS 27 (production build):

- When the composer was focused, the keyboard covered the bottom of the agent chat. "What should Claude do?" was cut off and the header seemed gone. The user wants the Telegram behavior: clip the top, not the bottom.
- Dismissing the keyboard was not smooth and moved nearby UI. The user wants to drag the keyboard down, as in Messages and ChatGPT.

## What changed

| Area | Before | After |
| --- | --- | --- |
| Agent chat transcript (pushed chat and workspace tab) | SwiftUI `ScrollView` with the composer in `.safeAreaInset`. The keyboard raised the inset, but the scroll offset stayed, so the keyboard covered the newest turns and the empty state. In a tab, the bottom margin came from `onGeometryChange` one layout pass later | `ChatTranscriptController` (`CmuxMobileAgentChat/ChatKeyboardDock.swift`). A UIKit `UIScrollView` hosts the turns. In the same layout pass, the bottom content inset is set to the composer's top and the content offset moves by the same amount, so the bottom of what you see stays on the composer and the top is clipped. This applies to a reader scrolled up too, as in Telegram. Content shorter than the screen sits on the composer |
| Composer (pushed chat) | Rode the keyboard through SwiftUI's keyboard safe area | Hosted by the controller in a tall transparent container. Its bottom is constrained to `view.keyboardLayoutGuide` (8 pt above the keyboard, or 8 pt above the bottom safe area), so UIKit moves it inside the keyboard's animation and with the finger |
| Composer growth (collapsed "Follow up" to expanded, attachments, queue) | The transcript jumped to the final height | The stack reports its height as drawn on every animation frame (`DrawnHeightReporter`, an animatable modifier). The transcript inset is set in the same SwiftUI update. The collapse on blur now animates (`ChatComposer.shownCollapsed`). Before, it snapped while the transcript eased |
| Empty state | Pushed down 220 pt inside the scroll content, then behind the keyboard | Centered between the header and the composer. It moves with the composer every frame |
| Interactive dismissal | `.scrollDismissesKeyboard(.interactively)`, but the inset lagged | `keyboardDismissMode = .interactive`. `keyboardDismissPadding` equals the composer height, so the keyboard starts following when the finger reaches the composer's top edge, as in Messages. A downward swipe on the composer also dismisses (UIKit pan when pushed, a SwiftUI drag in a tab) |
| Workspace tab composer (TabsKit accessory) | Followed the keyboard below the toolbar during a drag, then jumped back up | `max(keyboard, resting place)` in `TabsView` |
| Jump-to-bottom button | Inside the stack | Pushed chat: its own host, anchored 4 pt above the composer, so it moves with it. Tab: still in the accessory |
| Header | Pushed: system navigation bar | Unchanged and stable (measured below). Tab: TabsKit draws no header; the status bar fade from `feat-cnx-ios` is kept |
| New Claude or Codex chat in a workspace | Opened unfocused | Opens with the composer focused and the keyboard up, as ChatGPT, Claude and Grok do (`chatgpt-01`, `claude-05`, `grok-01` in the reference pack) and as SPEC 6.2 says |
| Feed | `ScrollView` with no keyboard dismissal | `.scrollDismissesKeyboard(.interactively)`. A focused answer field scrolls above the keyboard and a downward drag dismisses it (checked on iOS 26.5) |

The iOS 27.0 simulator has a quirk. There, `UIKeyboardLayoutGuide` never left the bottom edge for this transcript, and Chief's conversation (`CmuxConversation`) showed the same problem. The terminal and SwiftUI's keyboard inset moved normally. The controller detects a docked keyboard that the guide did not follow. It then switches to the keyboard's frame notifications, applied inside their animation. While a drag dismisses the keyboard, it also reads the keyboard as drawn on every frame (`KeyboardProbe`). On iOS 26.5 the guide path is used throughout.

The hardware-keyboard case from `feat-cnx-ios-e2e` (the guide reporting a 0-wide frame near the top) is handled: the pin switches off unless the guide spans the width and touches the bottom. The chat dogfood note in `chat-dogfood.md` was also handled: these runs use the software keyboard, and no hardware keyboard was attached.

## How it was measured

- Headless iPhone 17 Pro simulators `cmux-mobile-kbd-ios26` (iOS 26.5) and `cmux-mobile-kbd-ios27` (iOS 27.0), dark appearance, Debug build, `CMUX_MOBILE_MOCK_AUTH=1`, software keyboard. Simulator.app was never opened.
- `verify/record-keyboard.sh <udid> <dir> <label> <demo>` opens a screen with a DEBUG demo (`kbd-chat`, `kbd-chat-empty`, `kbd-tab`, `kbd-empty`), then drives the keyboard with real HID touches through AXe:
  1. Tap the composer.
  2. Swipe down on the composer.
  3. Tap again.
  4. Drag the transcript from y = 250 to 860 pt over 1.6 s, which is an interactive dismissal.

  `simctl io recordVideo` records, and `verify/scripts/frames.sh` splits every recorded frame.
- `-cmux-mobile-kbd-trace` makes the app write one line per display frame from presentation layers: the keyboard as drawn, the composer card, the transcript's last row, the empty state's centre and the navigation bar. `verify/scripts/kbd_trace.py` reports each transition:
  - `gap`: keyboard top minus composer bottom.
  - `lag`: keyboard progress minus composer progress, times the composer's travel.
  - `cgap`: composer top minus transcript bottom; for the empty state, the centre's offset from the middle of the open area.
  - `jump`: the largest one-frame change of `cgap`.
  - `header`: the header's position.
- `verify/scripts/kbd_pixels.py` measures the recorded frames independently from pixels (keyboard top, composer edges, the lowest transcript row, header row).

Evidence (git-ignored): `verify/evidence/kbd/`. It holds `<sim>-<screen>.mp4`, `-frames/`, `.trace.txt`, `.trace-summary.txt` and `.pixels.txt`, plus `ios26-messages.*`.

## Results (app trace, points)

`gap` is listed only while the keyboard is above the composer's resting place. A docked gap of 8 is the design. During show and hide the composer interpolates between its resting place and the docked place on the keyboard's own curve. The gap is therefore larger mid-animation (up to the 34 to 77 pt rest gap) and is never negative.

| Run | Show: lag / cgap / jump | Hide (composer swipe): lag / cgap | Drag dismissal: gap | Header top |
| --- | --- | --- | --- | --- |
| iOS 26 pushed chat | -0.26..0.14 / 7.84..8.17 / 0.31 | -0.11..0.21 / 7.83..8.16 | 8.00..8.00 | 62.00 every frame (2023) |
| iOS 26 pushed, empty | -0.01..0.01 / 0.00..0.17 / 0.04 | -0.01..0.01 / 0.00..0.17 | 8.00..8.00 | 62.00 (1420) |
| iOS 26 tab chat | -0.26..0.12 / 7.84..8.16 / 0.32 | -0.15..0.17 / 7.84..8.16 | 8.00..16.33 | no header (TabsKit) |
| iOS 26 tab, empty | -0.01..0.01 / 0.00..0.17 / 0.05 | -0.00..0.01 / 0.00..0.17 | 8.00..27.00 | no header |
| iOS 27 pushed chat | -0.01..0.01 / 7.83..8.16 / 0.29 | -0.01..0.01 / 7.83..8.16 | 8.00..19.00 | 62.00 (2122) |
| iOS 27 pushed, empty | -0.01..0.01 / -0.01..0.01 / 0.01 | -0.01..0.01 / 0.00..0.01 | 8.00..21.00 | 62.00 (1555) |
| iOS 27 tab chat | -0.01..0.01 / 7.84..8.17 / 0.32 | -0.01..0.01 / 7.84..8.16 | 8.00..10.00 | no header |
| iOS 27 tab, empty | -0.01..0.01 / -0.01..0.01 / 0.01 | -0.01..0.01 / -0.01..0.01 | 8.00..27.00 | no header |

Reading the table:

- The composer follows the keyboard's curve to within 0.26 pt in every show and hide. The transcript's last row stays 8 pt above the composer, within 0.17 pt on every frame. This holds while the composer expands from "Follow up" to the full card and collapses back, and while the keyboard moves. The empty state stays centred within 0.17 pt. The pixel measurement agrees: the transcript bottom moved with the composer to within 0.33 pt per frame in every show on both simulators (`cgap 38.0..38.7`; 38 pt is the distance from the action row's icons to the card).
- The header does not move: the navigation bar's top is 62 pt in every recorded frame on both versions (pixels: title row 69.7 pt in all frames).
- Drag dismissal on iOS 26 (guide path): the composer sits exactly 8 pt above the keyboard on every frame while the finger drags it.
- Drag dismissal, workspace tab: the composer is the TabsKit accessory, moved by SwiftUI's keyboard inset. It trails the finger for the first 2 to 3 frames of the drag (up to 19 pt, gap 27), then rides 8 pt above the keyboard.
- Drag dismissal on iOS 27 (notification and probe path): one frame behind the drawn keyboard, a steady 14.3 pt gap (6.3 pt of travel per frame) instead of 8.
- One frame per show where the keyboard's placeholder reports its final frame before its animation attaches is dropped and counted (`placeholder spikes`). The recordings show no keyboard pixels in that frame.

## Reference comparison

| | Messages (iOS 26.5 simulator, `ios26-messages`) | ChatGPT, Claude, Grok (reference pack, iOS 27 device stills) | mobile agent chat |
| --- | --- | --- | --- |
| Composer above a docked keyboard | 16 pt, same curve | about 8 pt | 8 pt, same curve (lag at most 0.26 pt) |
| Header while the keyboard is up | Stays (title row 82.3 pt in all 540 frames) | Stays | Stays (62 pt in every frame) |
| Content | Bottom glued to the composer, top clipped | Empty state centred above the composer | Both |
| Interactive dismissal | Drag pulls the keyboard; the field rides it | Drag pulls the keyboard (ChatGPT, Claude) | Same; also a swipe down on the composer |
| New chat | n/a | Keyboard up on a new chat | Keyboard up on New Claude or Codex Chat |

## Open items

- Workspace tab drag dismissal: the 2 to 3 frames of trailing come from SwiftUI's keyboard inset in `CmuxTabsKit`. Pinning the accessory to a UIKit keyboard layout guide in TabsKit would remove it. That would change the shared package (it also places the terminal's key bar), so it was left for the TabsKit owner.
- The iOS 27 simulator guide quirk is not explained. On a real iOS 27 device, Chief behaves like Messages (per the user), which suggests the device guide works and the fallback stays idle there. This was not checked on a device (no real-phone verification was requested).
- New workspaces created from the Workspaces list (`New Claude Workspace`) still open unfocused. Only new tabs focus.
- The Setup and New-workspace text fields were not changed: neither has a keyboard-pinned composer.
