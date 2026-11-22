# CmuxScreenKit

See and control a Mac's screen from an iOS app. This is the library behind
the cmux VNC demo apps (`experiments/cmux-vnc-ios`), which use it as their
only screen code.

| Product | Platforms | What it holds |
| --- | --- | --- |
| `CmuxScreenKit` | iOS 17, macOS 14 | `ScreenSession` (connect, reconnect, input, quality, stats), `ScreenPreferences`, `OrientationLock`, `ScreenPerfLog`; re-exports `CmuxVNC` and `CmuxVNCWebRTC` (`VNCPairing`, `VNCEndpoint`, `VNCKeysym`, `ScreenQuality`, …) |
| `CmuxScreenKitUI` | iOS 17 | `ScreenSessionView` (full-screen, features opt-in), `ScreenView` / `ScreenViewController` (the screen alone), `MacShortcutsBar`, `ScreenOrientation`, `PairingScanner` |

## Add it

SwiftPM, local path (Xcode: Add Package → Add Local…):

```swift
.package(path: "<repo>/Packages/Shared/CmuxScreenKit")
// target dependencies:
.product(name: "CmuxScreenKit", package: "CmuxScreenKit"),
.product(name: "CmuxScreenKitUI", package: "CmuxScreenKit"),
```

XcodeGen: see `experiments/cmux-vnc-ios/project.yml`.

## Connect to a Mac

A Mac runs a screen host and shows a pairing link (`cmux-vnc://pair?…`):
the Swift host (`cmux-vnc-host --capture`, Packages/Shared/CmuxVNCWebRTC) or
the Rust host (`cmux-screen/`). Both serve the same protocol over WebRTC,
through the cmux-vnc-signal Worker, with Cloudflare TURN when there is no
direct path.

```swift
import CmuxScreenKit
import CmuxScreenKitUI

let pairing = VNCPairing(link: URL(string: link)!)!     // nil for anything that is not a pairing link
let session = ScreenSession(title: pairing.name, pairing: pairing)
session.connect()
```

Other targets: `ScreenSession(title:endpoint:credentials:)` for a VNC server
reached directly, `ScreenSession()` for the built-in demo desktop.

## Show it: everything

```swift
@State private var session: ScreenSession?

.fullScreenCover(item: $session) { session in
    ScreenSessionView(session: session, features: .all) { self.session = nil }
}
```

`ScreenSessionView` closes the session when it goes away.

## Pick features

`ScreenFeatures` is an option set. `.all` is the demo app; `.minimal` is the
screen with a close button, state cards and display paging.

| Feature | What the user gets |
| --- | --- |
| `.shortcutsBar` | One-tap Mac shortcuts under the toolbar: Spotlight, Mission Control, App Windows, Switch App, Copy, Paste, Undo, Select All, New Tab, Close Window, Quit App, Screenshot, Force Quit, Lock Screen. Change the row with `shortcuts:` (`MacShortcutsBar.Shortcut`). |
| `.qualityMenu` | Quality in the options menu: Auto, Smooth Motion, Fixed Low (720p), Medium (1080p), High (full). |
| `.orientationLock` | Auto-Rotate / Portrait / Landscape, remembered. **Needs the app delegate hook below.** |
| `.fitToggle` | A Fit to Display toggle. Fitted mode itself (`preferences.fitToDisplay`, on by default) pins the view to one display: zoom out stops at its fit and panning stays inside it. |
| `.displayPaging` | Swipe at fit, or tap the page dots, to move between the Mac's displays. |
| `.stats` | The live line: path (Direct/Relay), fps, KB/s, round trip, codec, plus its toggle. |
| `.keyboard` | The keyboard button: the software keyboard with an Esc, Tab, arrows, Home/End, ⌃ ⌥ ⌘ (sticky) and F-key bar. Hardware keyboards work without it. |
| `.sendKeysMenu` | Send ⌃⌥⌦, ⌘⇥, ⌘Space and Esc from the options menu. |
| `.refresh` | Refresh Screen. |
| `.hideToolbar` | Hide the toolbar; a chevron brings it back. |
| `.resumeOnForeground` | Reconnect at once when the app returns after the stream dropped. |
| `.inputModeToggle` | Direct Touch / Trackpad in the options menu (`preferences.inputMode`). |

```swift
ScreenSessionView(session: session, features: [.displayPaging, .keyboard, .shortcutsBar, .resumeOnForeground]) { … }
```

Always on: the touch input model (below) and the connecting, reconnecting,
sign-in and error cards.

## Input

`session.preferences.inputMode` (`ScreenInputMode`, saved with the other
preferences; `.direct` by default and for preferences saved before it):

| | Direct Touch (`.direct`) | Trackpad (`.trackpad`) |
| --- | --- | --- |
| One finger | Tap clicks where you touch; two quick taps double-click (at one point); press-and-hold then drag drags; on a zoomed view, pans it | Moves a cursor (faster strokes go further); tap clicks at the cursor, two taps double-click; tap then touch again and drag, or a long press, drags; a zoomed view follows the cursor |
| Two fingers | Tap right-clicks where you touch; drag scrolls what is under them | Tap right-clicks at the cursor; drag scrolls under the cursor |
| Pinch | Zooms | Zooms |

In trackpad mode a cursor is drawn locally even when the Mac sends no
cursor shape, and a tap holds the button for 0.25 s before releasing it, so
a touch inside that time continues the press as a drag (as on a Mac
trackpad). Display paging there is by the page dots.

Sticky ⌃ ⌥ ⌘ (the keyboard bar) also apply to the next click or drag: the
keys go down before it and up after it (`session.click(_:modifiers:)`); a
host that lists `mods` applies held modifiers to every mouse event until
their key up.

On iPad with a mouse or trackpad: hover moves the remote pointer, the
primary button clicks and drags at once, the secondary button right-clicks,
the wheel and two-finger scrolling scroll the Mac, and the system pointer
hides over the screen. Buttons need `UIApplicationSupportsIndirectInputEvents`
= YES in the app's Info.plist (without it a click arrives as a touch).

Scrolling is smooth (pixels) when the Mac says it takes it: a newer host
sends `{"t":"caps","s":"scroll-px,mods"}` (a comma list, on the ordered
channel before the first `displays`) when the input channel opens
(`ScreenStreamViewer.onCapabilities`); `session.hostCapabilities` holds it and `session.supportsPixelScroll`
reads it, and scrolls then go as `{"t":"scroll","x":..,"y":..,"dx":..,"dy":..,"u":"px"}`
(`dx`/`dy` in pixels of the streamed video frame, positive where the
content moves right and down; the host turns them into its own scroll
units). An older host sends no `caps` and gets wheel lines, as before.

Apply a mode to a live screen: `ScreenView(…, inputMode:)` (nil follows
`session.preferences.inputMode`) or `ScreenViewController.inputMode`.

Orientation lock needs one line in the app delegate:

```swift
func application(_ application: UIApplication,
                 supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    MainActor.assumeIsolated { ScreenOrientation.shared.allowed }
}
```

## Bring your own chrome

`ScreenView(session:fitToDisplay:displayPaging:keyboardVisible:inputMode:)` is the
screen alone (SwiftUI). `ScreenViewController(session:)` is the same thing
for UIKit. Drive everything else from `ScreenSession`:

- state: `phase` (`.connecting`, `.connected`, `.failed(message:needsSignIn:)`, `.ended`), `isReconnecting`, `stats`, `streamPath`, `frameSize`;
- input: `tap(_:modifiers:)`, `type(_:modifiers:)`, `key(_:down:)`, `click(_:)`, `click(_:modifiers:)`, `movePointer(to:)`, `press(_:down:)`, `scroll(dx:dy:)` (lines), `scrollPixels(dx:dy:)` (when `supportsPixelScroll`); `hostCapabilities`;
- `relayOnly`: connect only through the relay server (for testing that path).
- control: `selectDisplay(_:)`, `preferences.quality` + `applyQuality()`, `refresh()`, `resumeIfNeeded()`, `connect()`, `reconnect()` (connect again with retries), `close()`.

`MacShortcutsBar(session:shortcuts:)` and `PairingScanner { link in … }`
(VisionKit, QR; check `PairingScanner.isSupported`) also work on their own.

## Behaviour

- **Reconnects.** A dropped stream reconnects on its own: up to
  `reconnectLimit` tries (default 5; 0 turns it off), after 0, 1, 2, 4 and
  8 s. A drop in the room (signaling) connection never ends a running stream.
- **Keep preferences per Mac.** `ScreenPreferences` is `Codable`. Store
  `session.preferences` when the session closes; `session.hostID` is free
  for your own key.
- **Timing log.** `session.perf = ScreenPerfLog()` turns on the
  input-to-frame log (Documents/perf.log). It is off by default.
- **Threads.** `ScreenSession` and every view are main-actor.

## Signaling: pairing rooms or the device hub

`ScreenStreamViewer` and `ScreenStreamHost` (CmuxVNCWebRTC) reach each other
through a `ScreenSignaling`: `send(_:)`, `messages()` (`ScreenSignal`:
`hello`, `peerJoined`, `peerLeft`, `offer`, `answer`, `candidate`, `bye`),
`iceServers()` and `close()`. Two implementations:

- `RoomSignaling(pairing:role:)`: a pairing link's room on the
  cmux-vnc-signal Worker. `ScreenStreamViewer(pairing:)` and
  `ScreenStreamHost(pairing:…).run()` use it exactly as before: the room is
  reopened when it drops and a connected stream outlives it.
- `TicketSignaling(ticket:signalURL:signer:iceServers:expectedPeerKey:)`: one
  device hub session (docs/device-hub/PROTOCOL.md). It opens
  `signalURL?ticket=<jws>` with the device headers from a
  `ScreenTicketSigner` (the app's Secure Enclave key), signs this side's DTLS
  fingerprint into every offer and answer (`fpSig` over
  `"<sid>|<role>|<fingerprint>"`, the `a=fingerprint:` values joined with
  `,`), and verifies the peer's against the ticket's `peerKey`. A missing or
  wrong `fpSig` aborts the session (`ScreenSignalingError`, `bye`, socket
  closed). `iceServers` is the session's list: the ticket's cmux relay and
  the user's relays. The ticket admits once, so the session ends with the
  socket (`endsSessionOnClose`).

```swift
let signaling = try TicketSignaling(ticket: push.ticket, signalURL: push.signalURL, signer: signer,
                                    iceServers: relays, expectedPeerKey: push.peer.signingKey)
// Viewer:
let viewer = ScreenStreamViewer(signaling: signaling)
try await viewer.connect()
// Host (a `view` session ignores all input but the display choice and refresh):
let host = ScreenStreamHost(name: "Studio", viewOnly: push.scope == "view", backend: { ScreenCaptureBackend(log: log) })
try await host.serve(signaling)
```

`ScreenStreamHost.disconnectViewer()` sends `bye` on a device hub session.
`ICEServerConfig` (urls, username, credential) is public for building the
list.

`ScreenSession(title:preferences:signaling:)` is a stream session whose
signaling the app supplies: each `connect()` asks the closure for the
connection to use (a ticket's `TicketSignaling`, which admits once) and
fails when it returns nil, so set `reconnectLimit = 0` and start a new
session for a new ticket. Input, quality and stats work as for a pairing.

`ICERelayCheck(servers:timeout:).run()` checks a TURN relay: a relay-only
peer connection gathers candidates, and `.relayed` means the relay gave
this device a `typ relay` address.

## Tests

`swift test` in this folder runs the tests that need no device. The UI target
builds for iOS only, through the demo apps
(`xcodebuild -project experiments/cmux-vnc-ios/CmuxVNCiOS.xcodeproj -scheme CmuxVNCiOS`).
