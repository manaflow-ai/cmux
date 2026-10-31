# Browser view freeze, 2026-10-24

The user (real iPhone, laptop cmux NIGHTLY, cmux-mobile-host `7822fca9f292`): "In a browser
view on iOS, after 3-5 minutes of usage it stopped responding to my gestures and the displayed
browser rendering was no longer being updated."

## The laptop's host log (read only, UTC)

One WireGuard link over TURN (`d437e5c7`, up 02:00:04) with a WebRTC media session beside it
(up 02:00:11). The person had several browser tabs, each a separate browser host process with its
own capture clock (its process start):

| Tab | Host started | Lane |
| --- | --- | --- |
| `s799` | 01:59:21 | lane from 01:59:21; channel from 02:02:19; lane again 02:06:38 |
| `s919` | 02:02:19 | lane 02:02:19 to 02:06:38 |
| third | 02:07:56 | lane from about 02:08:35 |

From about 02:03:54 the host's lane counter `keyframe_requests` (PLIs from the phone) climbs
at 2 to 5 per second (16 at 02:03:34, 942 at 02:07:28, 1519 at 02:10:21) while the host keeps
sending 2 to 8 frames a second at near zero loss. At 02:10:29 the media session fails and video
moves into the tunnel: the counter jumps by about 900 in 15 s. The link dropped at 02:10:46
(keepalive). The phone kept asking for keyframes and showed none.

## Root causes

1. **The phone's lane gate compared RTP timestamps across tabs.** The gate (media/mod.rs) passes
   a keyframe from another route only when its timestamp is newer than the newest it passed. A
   timestamp is the tab's host capture time, so a tab opened minutes later is minutes behind. Once
   such a tab held the lane, every route switch (media session failed or stalled, video moving
   into the tunnel) left every one of its keyframes rejected, and the gate asked for another every
   250 ms, until that tab's clock caught up: minutes of a frozen page. Fix: the newest timestamp
   per tab tag. Test `a_later_tabs_keyframe_on_the_next_route_passes_although_its_clock_is_behind`
   (red: `RejectAndAsk`).
2. **A dead decoder session was never replaced.** A decode failure kept the VideoToolbox session
   and only new parameter sets made a new one; a session iOS invalidated (background) failed every
   keyframe and asked again forever. Fix: a failed decode drops the session. Test
   `DecoderTests.aDeadSessionIsReplacedAtTheNextKeyframe`.
3. **A hidden tab's keyframe request reset the shared lane.** A decoder of a tab whose video was on
   the channel asked the lane too, restarting the shown tab's lane frames at a keyframe. Fix: the
   request goes where that tab's frames come from; a viewer waiting for its first lane keyframe asks
   at most every 250 ms.

## Watchdogs

- Library viewer: input the host has not acknowledged for 5 s, or a channel write that waited 5 s,
  ends the stream as `stalled`. Test
  `input_the_page_never_acknowledges_ends_the_stream_as_stalled` (red: timed out).
- App (`BrowserStallWatchdog`): while a page is shown, no picture for 10 s (2 s after input) asks
  for a keyframe; unanswered for 3 s restarts the decoder, for 6 s opens the stream again. That and
  a `stalled` close show "Reconnecting browser…" until the first picture. Tests in `StallTests.swift`.

## Rig soak

See `verify/browser-freeze/` (filled in by the soak runs).
