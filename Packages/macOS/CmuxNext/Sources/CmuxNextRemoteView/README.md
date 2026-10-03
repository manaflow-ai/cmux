# CmuxNextRemoteView

The remote desktop pane (plans/cmux-next/remote-desktop.md section 7): decode, present, chrome and input capture for one `cmux.rd/1` stream. Transport neutral: the App supplies a `RemoteViewStreamSource` and a `RemoteViewInputSink`. `MockRemoteStreamSource` encodes synthetic frames with VideoToolbox, so the pane runs with no host. Not wired into the app yet.

Debug builds only: `RemoteDesktopPane`, its view and the mock host compile out of Release and NIGHTLY (`RemoteViewAvailability.isAvailable`) until the overlay link token authenticates the viewer's hello claims. The connecting and consent cards say so.

## Settings the viewer reads

`RemoteDesktopSettingsTests` checks this table against `RemoteDesktopSettings()`.

| Key | Default | Values |
| --- | --- | --- |
| `remoteDesktop.quality` | `auto` | `auto`, `sharpText`, `smoothMotion`, `lowBandwidth` |
| `remoteDesktop.maxFps` | `auto` | `auto` (display refresh) or 1 to 240 |
| `remoteDesktop.maxBitrateMbps` | `auto` | `auto` (congestion control, cap 80) or 0.1 to 80 |
| `remoteDesktop.codec` | `auto` | `auto`, `h264`, `hevc`, `av1` |
| `remoteDesktop.resolution` | `matchPane` | `matchPane`, `hostNative` |
| `remoteDesktop.keyboard.mode` | `auto` | `auto` (physical keys unless the input source cannot type ASCII), `physical`, `text` |
| `remoteDesktop.keyboard.sendSystemShortcuts` | `false` | `true` sends Cmd-Tab, Cmd-Space, Spaces and cmux shortcuts to the host |
| `remoteDesktop.clipboard` | `ownDevicesOnly` | `ownDevicesOnly`, `always`, `never` |
| `remoteDesktop.audio` | `false` | `true`, `false` |
| `remoteDesktop.interactiveMaxRttMs` | `80` | above this RTT the pane is view only until "Control Anyway" |
| `remoteDesktop.showPathBadge` | `true` | the path and RTT badge in the toolbar |

Debug Settings (DEV and NIGHTLY): `remoteDesktop.debug.presenter` = `metal` (B, default), `layerContents` (A), `sampleBuffer` (C).

Mouse buttons on the wire (`RemoteMouseButton`): 1 left, 2 middle, 3 right, 4 to 7 reserved for scroll, 8 back, 9 forward. Hosts map from these numbers.

The relay caps (`remoteDesktop.relay.maxFps` 15, `remoteDesktop.relay.maxBitrateMbps` 4, section 6.6) are team policy that the host and engine read, so this module does not read them.

The release chord Control-Option-Escape (`remoteDesktop.releaseKeyboard`) always returns the keyboard to the viewer.
