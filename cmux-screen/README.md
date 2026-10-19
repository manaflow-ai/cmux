# cmux-screen

The cross-platform Rust implementation of cmux screen streaming: this
computer's screen goes to a cmux viewer (the cmux VNC iOS app today) as a
WebRTC video track, and the viewer's touches and keys come back on WebRTC
data channels.

Viewers reach the host two ways (design: `plans/cmux-next/remote-desktop-v2.md`):

- **Tailnet (default).** The host is its own device on the user's tailnet
  through embedded Tailscale (`cmux-tailnet`, libtailscale), named
  `cmux-<computer>`; no Tailscale app is needed. The first run prints a
  sign-in link. Each viewer connection is identified with Tailscale WhoIs and
  served only if it is the owner's device (or on `--allow`). Media goes over
  the tailnet too: the host runs a TURN-over-TCP relay on tailnet port 4181
  and gives each tailnet viewer its own credentials in an `ice` signaling
  message, so a host with embedded Tailscale only (no OS tailnet interface)
  still streams over the tailnet. Check: `scripts/tailnet-turn-check.sh`.
- **Worker room (fallback).** The pairing link and Cloudflare TURN, for
  viewers with no tailnet. `--no-room` turns it off.

It speaks the same wire protocol as the Swift host in
`Packages/Shared/CmuxVNCWebRTC`, so the iOS app pairs with either host
unchanged and both share `~/.config/cmux-vnc-host/pairing.json`.

## Layout

| Crate | What it holds |
| --- | --- |
| `cmux-screen-proto` | Pairing links, room signaling messages, input and host messages, quality presets. Pure Rust, every platform. |
| `cmux-screen-host` | The host: tailnet and room signaling, WebRTC sessions, quality, reconnect rules, and the platform backends. |
| `cmux-tailnet` | This install as a tailnet device: libtailscale node, sign-in events, TCP listen and dial, WhoIs, the owner-only access check, and (feature `relay`) the media TURN relay. CLI `cmux-tailnet up/serve/dial/forward/turn-serve/turn-check`. |

WebRTC is Google's libwebrtc through LiveKit's `libwebrtc` crate, so
congestion control, hardware encoders (VideoToolbox, NVENC, VA-API),
ICE/TURN and data channels are WebRTC's own. The host only sets standard
sender parameters for the viewer's quality choice.

Session rules (same as the Swift host): once the input channel is open, only
WebRTC ends a session; a dropped room connection on either side is reopened
quietly and the stream continues.

## Platforms

| Platform | Capture | Input | State |
| --- | --- | --- | --- |
| macOS | ScreenCaptureKit, NV12, zero copy to VideoToolbox | CGEvent | Working; measured below |
| Windows | libwebrtc desktop capturer (`--backend desktop`) | not yet (SendInput) | Capture builds on the shared backend; untested |
| Linux | libwebrtc desktop capturer: X11, PipeWire on Wayland | not yet (XTest, RemoteDesktop portal) | Capture builds on the shared backend; untested |

macOS needs Screen Recording and Accessibility for the host process or the
app that starts it.

## Build and run

```bash
cargo build --release                                        # needs Go 1.27 for libtailscale (GOTOOLCHAIN=auto)
./target/release/cmux-screen-host --name "My Mac"            # prints the sign-in link, then the pairing link
./target/release/cmux-screen-host --tailnet-auth-key-file -  # headless sign-in with a one-time auth key on stdin
./target/release/cmux-screen-host --no-room                  # tailnet only
./target/release/cmux-screen-host --no-tailnet-relay         # tailnet signaling, no media relay
./target/release/cmux-screen-host --backend desktop          # libwebrtc's capturer instead
```

`build.rs` links with `-ObjC` (libwebrtc's Objective-C categories; without
it the factory aborts at startup) and adds `/usr/lib/swift` to the rpath
(screencapturekit's Swift bridge).

## Measured (2026-10-13, mini 2, macOS 27)

Glass-to-glass under consecutive input (`MarkerLatencyTests` in the Swift
package as the viewer, same Mac): keys at 2/20/50 Hz p50 43/53/40 ms, pointer
moves at 60 Hz p50 63 ms; Swift V2 host on the same test: 53/51/52 and 55 ms.
iOS simulator through the signal Worker: input to first frame p50 30 ms.
