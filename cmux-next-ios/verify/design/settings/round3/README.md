# Settings design loop, round 3 (implementation)

2026-10-14. One headless simulator, `cmux-mobile-settings-impl` (iPhone 17 Pro,
iOS 27.0, deleted afterwards), Debug build, input through `axe`. **Mock data
(layout only)** (`CMUX_MOBILE_MOCK_AUTH=1`). The sample data now has workspaces on
Personal's same-name Macs (`site` on 3F2A, `photos` on the asleep 91C7), so
the folded Workspaces row shows a tag. Stills only; the 1-minute load average
was 37.5 at the start and 27.5 at the end.

| File | Shows |
| --- | --- |
| `img/F-devices-ax5-tag-under-name.png` | Devices at AX5, dark and light: names unbroken, tag capsule on its own line (capped at 22 pt), then presence |
| `img/F-workspaces-folded-row-tag.png` | Personal's folded row for the asleep 91C7: Large (name, capsule, "Last seen 3d ago" on one line) and AX5 (stacked), dark and light |
| `img/LS-last-seen-shared-clock.png` | MacBook Pro "Last seen 2h ago" in the list, the filter menu and Devices; a row stamp reads "1m" |
| `img/G-no-invite-on-personal.png` | Sidebar and team page on Personal: no "Invite to team" |
| `screens/*.png` | All captures |
