# Settings design loop, round 1 (implementation)

Captured 2026-10-14 on one headless simulator, `cmux-mobile-settings-impl` (iPhone 17
Pro, iOS 27.0, 402 x 874 pt, deleted afterwards), Debug build
`dev.cmux.mobile.simplDebug`, input through `axe`.

**Every capture is mock data (layout only)** (`CMUX_MOBILE_MOCK_AUTH=1`): sample
user, teams and Macs. Layout and copy are real; counts and presence are sample
data. Production was built for the simulator (no Settings → Developer, no
Relay only, no mock strings in the binary) but not captured: it stops at the
signed-out Welcome.

Load: page captures began at a 1-minute load average of 35.9 (ended 16.4);
the editor recording ran at 14.8 to 16.9 at start, and the load rose (another
session) to 73 by its last second, so treat its final frames' timing loosely.
Stills are unaffected.

| File | Shows |
| --- | --- |
| `img/00-pages-<page>.png` | Each page: dark Large, light Large, dark AX5, light AX5 |
| `img/01-root-scroll-dark.png` | Root, scrolled top to bottom |
| `img/03-team-editor.png` | Editor: open; Custom opens the emoji keyboard with the grid above it; emoji picked (keyboard away, Done back); None; light; AX5 checklist |
| `img/10-devices-remove.png` | Swipe Remove and the tagged confirmation |
| `img/12-setup-and-sidebar.png` | Setup's space chooser (one Personal) and the sidebar |
| `video/team-editor-emoji-dark-402w.mp4` | Open editor, Custom, Blue with the keyboard up, pick an emoji, None, Done |
| `screens/*.png` | All captures |
