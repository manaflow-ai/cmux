# Streamed browser tabs (video)

Branch `feat-cnx-ios-browserstream`, 2026-10-13. A workspace's browser tab on
the phone shows the Mac's browser page as H.264 video. Touches, scrolls and
typing go back to the page, and the page's URL, title and navigation state
drive the TabsKit toolbar and address bar.

## Decision: carry `cmux.rb/1` over the link (option a), stream carrier first

The Mac already has a complete remote browser stack: `cmux.rb/1` (the browser
tab service) on `cmux.rd/1` (the remote desktop media protocol). The cmux-next
app runs it for its own remote browser tabs. The parts are:

- `cmux-remote-browser-host`, the CEF fork host bundled in DEV builds at
  `Contents/Helpers/cmux-remote-browser-host.app`, which the app starts with
  `LocalRemoteBrowserHost`;
- VideoToolbox IOSurface encode (`cmux-encode`);
- the shared media engine (`cmux-rd-engine`: frame gate, delay-based
  congestion control, quality ladder, packetizer with FEC, NACK history,
  keyframe and recovery);
- the viewer core (`cmux-rd-ffi`: reassembly, loss feedback, clock probes,
  exactly-once input).

The phone reuses that stack unchanged. Nothing is added to the media path.

| Criterion | (a) rb/rd over the link | (b) WebRTC media track (RTP H.264/HEVC) |
| --- | --- | --- |
| Glass-to-glass latency | No jitter buffer: a frame shows the moment its last shard arrives. Input is sequenced and exactly-once, with a host-side gap timeout. | libwebrtc adds a jitter buffer and playout delay. You can push it toward 0, but the receive pipeline is tuned for calls, not UI. |
| Cellular quality | Delay-based congestion control and FEC already exist. NACK uses a 16-frame history, and recovery frames reference an acknowledged frame instead of forcing an IDR. | GCC, NACK and PLI are mature. That is (b)'s real advantage, but only on the WebRTC transport. |
| Battery | Hardware decode with VideoToolbox. Rust shard reassembly is cheap. | Hardware decode too. libwebrtc is a second large media stack running on the phone. |
| Reuse of the Mac host | 100%: the app's own host, encoder and engine. | The host would need an RTP sender, a second packetizer and congestion controller, and per-transport media logic. |
| Transport-agnostic (PROTOCOL.md) | Yes: any link channel carries it, over WebRTC and over WireGuard (direct, TURN or relay). | WebRTC only. WireGuard would still need (a), so you build both. |
| Input and page metadata | rb input events (pointer, wheel with phases and momentum, pinch, key, IME) and `rb.page`, `rb.history`, `rb.navigate`, `rb.screen` already exist. | You would need a data channel for these anyway, which is (a)'s control plane. |

Choice: (a) everywhere.

The MVP carries the rd **stream carrier** (`u8 kind, u32 len` frames, as the
app's loopback viewer uses) inside one reliable `browser` link channel.

The upgrade path is additive and needs no change to rb or rd:

- a datagram lane per link, carrying rd datagrams with `Carrier::Datagram`.
  The viewer core supports it already.
  - On WebRTC: a second data channel, unordered with `maxRetransmits=0`.
  - On WireGuard: a UDP overlay port next to the smoltcp stream.
- With that lane, FEC and NACK replace TCP-style retransmission. A lost
  packet then no longer stalls every later frame (head-of-line blocking).

The data-channel lane is the right next step for lossy cellular paths. It
touches the link's channel table, which the input and priority work
(termlive) is changing now, so it lands after that work merges.

## Architecture

```
iPhone (CmuxMobileKit)                       Mac: cmux-next DEV app
TabsKit page                          IPhoneHostService ─ MobileHostSupervisor
 StreamedBrowserPage                          │ stdin/stdout control lines
  AVSampleBufferDisplayLayer ◀─ VTDecompressionSession    ▼
  gestures, UIKeyInput ─▶ rb input      bundled cmux-mobile-host: `browser` service
 StreamedBrowserModel (rb.page → toolbar)     │ need_browser {request, tab, url}
cmux-mobile-link-ffi BrowserStream (Rust)                  ▼
 cmux-rd-ffi Session + InputChannel    IPhoneBrowserHosts → LocalRemoteBrowserHost
        ▲  rd stream carrier bytes             │ (the app's own bundled CEF host)
        └──── link channel `browser` ─────────▶ cmux-remote-browser-host --serve
              (WebRTC or WireGuard)              loopback rd stream carrier
```

- **Phone.** It opens `browser {tab, url}`, where `tab` is the daemon tab id
  (`s<surface>`).
  - Rust runs the rd viewer core. Swift receives whole access units, each
    with its capture time and age.
  - `rb.open` and `rb.screen` lay the page out at the page view's size in
    points. The scale is the screen scale capped at 2, so a 402×705 pt page
    renders at 804×1410 px.
  - Input:
    - A tap sends pointer move, down and up.
    - A one-finger pan sends precise wheel events with phases. A fling sends
      momentum wheel events (decay 0.95 per frame).
    - Pinch sends `pinch`.
    - Typed text goes as `ime_commit`. Return, Tab and Backspace go as keys.
  - The keyboard toggles from a glass button on the page, because the host
    does not report a focused text field yet.
- **hostd.**
  - It asks the app for a host for each tab (`need_browser`) and sends the rd
    `hello` with the host's per-launch secret. The phone never sees the
    secret.
  - It splices the carrier. Phone frames are filtered: datagrams pass, and of
    rd control only viewer rb messages and `stop` pass. `rb.navigate` must be
    http, https or `about:blank`, and a second `hello` and bulk frames are
    dropped.
  - A host outlives its channel. Reopening the tab takes the host over: the
    older channel closes with `replaced`, and the page and its history stay.
  - At most 4 hosts run (`CMUX_MOBILE_RB_MAX_TABS`), and the least recently used one
    is stopped (`browser_stop`).
- **App.** `IPhoneBrowserHosts` (DEBUG, like the host it bundles) starts one
  `LocalRemoteBrowserHost` per phone tab, answers with port and secret, and
  reports `browser_gone` when the host exits. A hostd restart stops them all.

## Verification

### What ran

**The Mac** was `mini-cmuxs-mac-mini-2`, user-local under
`~/cmux-next-ios-e2e/browser`. It ran the real fleet DEV build
`cmux DEV cmux-mobile-br-2` (job `8c3a903da5d6`, commit `9473c44a8114`), launched
in the Mac's GUI session by `verify/scripts/browser-mac.sh`:

- `CMUX_NEXT_CONFIG_FILE` pointed at a private `cmux-next.json` with
  `mobile.allowIPhoneConnections: true`.
- `CMUX_AUTH_CREDENTIALS_FILE` (0600) held the `CmuxAuthRuntime` DEBUG dev
  credential.

From there the app did everything:

- It started its bundled `cmux-mobile-host`, built from this branch by the fleet,
  which registered in the personal space.
- On the phone's request it started its own bundled
  `Contents/Helpers/cmux-remote-browser-host.app` (CEF fork). That process's
  parent is the `cmux DEV` app process.

There was no standalone helper or test host. A python `http.server` on
loopback served only the test page, `clock.html`. It shows the Mac's wall
clock to the millisecond, a text field, a button, a link and 80 rows.

`browser-mac.sh seed` created the workspace `browser-demo` with a browser
tab (`s14`) on that page in the app's own daemon.

**The phone** was the headless simulator `cmux-mobile-br-ios26` (iPhone 17 Pro,
iOS 26.5), running a Debug build. Simulator.app was never opened.

- It signed in with the same credential (`verify/record-browser.sh`).
- The launch argument `-cmuxMobile.live.mac.<team> <device id>` picked this Mac,
  because three Macs on the mini share the name "cmux's Mac mini (2)".
- Taps, swipes and typing came from real HID events (`axe`).

**Measurements:**

- The overlay shows capture-to-decoded latency, from the rd clock probes and
  the frame's capture time.
- `verify/scripts/browser-latency.py` computes glass-to-glass from OCR of
  each still: the phone's wall clock in the overlay, minus the page's clock
  as streamed, minus the Mac clock offset. The offset was 2 to 3 ms over one
  ssh session (`clock-offset.py`).
- A still's two clocks can be up to one display frame apart.

### Results

Evidence is git-ignored, in `verify/evidence/2026-10-13/browser-stream/`
(recordings, app logs, `latency.txt`, the Mac hostd log).

| Check | Result |
| --- | --- |
| Open a workspace's browser tab | Workspaces, then `browser-demo`, then the browser card. hostd asked the app (`need_browser`), the app started its host, and the first frame arrived about 0.9 s after the tap. A reopen reuses the host: the first frame is at 2400×1600 (the host default), then 804×1444 after `rb.open`. |
| Viewport and DPR | 402×722 pt page at scale 2, so 804×1444 px frames. The page lays out at phone width (no horizontal scroll). |
| Taps | "Tap me" twice: the page counts `taps: 2`. Tapping the link loads `?page=2`. |
| Typing | Focus the field, then type "hello from iPhone" (`ime_commit`). The page echoes `typed: hello from iPhone`. |
| Scroll | Swipes scroll the page (rows 10 to 22 in view) with momentum. TabsKit's toolbar collapses on scroll, as for local tabs. |
| Toolbar | The address shows `127.0.0.1` from `rb.page`. Back is enabled after the link. Back (`rb.history`) returns to page 1 with the typed text intact. |
| Takeover | Each relaunch's channel took the host over. The older channel closed with `replaced`, and the page and its history stayed for the whole session (one host, pid 84425). |

| Run (25 s each) | Path | Frame rate | Bitrate | Capture to decoded | Glass to glass (OCR) |
| --- | --- | --- | --- | --- | --- |
| WireGuard, static page with clock | direct (LAN) | 55 to 57 fps | 0.69 to 0.80 Mbit/s | 12 to 17 ms | p50 8, p90 24, max 40 ms (n=45) |
| WebRTC, same | direct | 54 to 55 fps | 0.68 to 0.81 Mbit/s | 10 to 14 ms | p50 14, p90 15, max 31 ms (n=44) |
| WebRTC while the mini was loaded (load average 20) | direct | 8 to 48 fps | 0.07 to 0.2 Mbit/s | 16 to 34 ms, one 147 ms | p50 66, p90 200 ms |
| WireGuard relay only (TURN), page scrolled throughout | turn, 13 ms RTT | 40 to 50 fps, two dips (12 and 3 fps) | 0.6 to 1.3 Mbit/s | 22 to 29 ms | p50 35, p90 52 ms (n=38) |

Decode time is 1.4 to 1.6 ms (VideoToolbox in the simulator).

In the first WebRTC run, a 1.2 s freeze coincided with the previous app
instance's WireGuard link timing out on the same hostd.

### Tests

- Rust (`cargo test`, `cargo clippy --all-targets -D warnings`):
  - hostd `browser.rs`: the frame filter, tab and URL rules, the hello, and
    the supervised broker (ask, answer, gone, stop, non-loopback refused).
  - `tests/host.rs`: the browser service over WebRTC, WireGuard and the
    relay against a stand-in host (test-only, `tests/support`). It covers
    the hello with the secret, video shards, `file:` navigate dropped,
    takeover with `replaced`, `forbidden` and `bad_request`.
  - `cmux-mobile-link-ffi/tests/browser.rs`: the exported viewer end to end over both
    transports. It covers frames with an age, `rb.screen_applied` at the
    phone's size, navigate, pointer and IME input reaching the page, and
    close.
- CmuxMobileKit (`CmuxMobileBrowserStreamTests` on the simulator):
  - the Annex-B splitter and AVCC;
  - the rb JSON;
  - the model (open at size, `rb.page` to the toolbar, `rb.screen`,
    history, navigate, waiting and reconnect, refusal);
  - **real VideoToolbox H.264** framed as the Mac sends it, decoded in order,
    with a P-frame skipped before the first keyframe.
- cmux-next `MobileHostTests`: event parsing, the answer lines, and the
  supervisor starting a browser host for a scripted hostd and stopping all
  of them at stop. The CmuxMobileHost sources and `MobileHostState` (an exhaustive
  switch the new events broke, fixed) ran under `swift test` on the mini,
  because the `nx-remote` build host `cmux-lawrence-2` did not resolve. The
  fleet DEV build compiled the whole app.

### Gaps

- **Same page as the Mac?** No. The phone's tab runs in its own app-started
  host (one CEF instance per phone tab), not in the Mac window's tab. The
  Mac app's local host takes one viewer at a time. Sharing it needs
  multi-viewer support in the host (`rb.open` from a second viewer, as
  section 5.1 allows).
- **DEBUG only.** The app bundles the remote browser host only in DEV builds
  (`embed-remote-browser-host.sh`, until tracker cx-0y2y). A Release app
  refuses `browser` as `unavailable`, and the phone shows the reason.
- **No datagram lane yet.** A loaded Mac or a lossy path stalls the reliable
  channel (the loaded run above). This is the next step, after termlive's
  link changes land.
- **Keyboard.** It opens from a button, because the host reports no focused
  editable (`rb.text_input` is not emitted).
- **Not carried or not rendered:** popup surfaces (`rb.surface.*`), menus,
  dialogs, file choosers, downloads, cursor and clipboard. Navigation does
  not update the daemon tab's URL.
- **Measurement limits.** The phone was a simulator on the same LAN as the
  mini. There was no cellular run; relay-only TURN was the stand-in.
