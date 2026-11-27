# Settings round 3 notes (implementation)

2026-10-14. One headless simulator, `cmux-mobile-settings-impl` (iPhone 17 Pro,
iOS 27.0, deleted afterwards), Debug build, input through `axe`. **Mock data
(layout only)** (`CMUX_MOBILE_MOCK_AUTH=1`). Stills only; the 1-minute load average
was 19.3 at the start and rose to 122 (another session) by the last still.

| File | Shows |
| --- | --- |
| `screens/1-setup-choose.png`, `1-after-personal.png` | Setup's "Choose a space": picking Personal opens Workspaces on Personal (`site` on 3F2A, the asleep 91C7 folded) |
| `screens/2-editor-keyboard-dark.png`, `-light.png` | Editor with the emoji keyboard up: preview, the whole "Color" header and the grid are pinned; only Icon scrolls |
| `screens/4-devices-dot-large.png`, `-ax5.png` | Devices status dot: 8 pt at Large, 16 pt (cap) at AX5, centered on the name's first line |

Not captured: VoiceOver speech (the spoken time now reads `MinuteClock.shared`
like the visible stamp; source change only).
