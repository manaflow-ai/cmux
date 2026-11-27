# Settings design loop, round 2 (implementation)

2026-10-14. One headless simulator, `cmux-mobile-settings-impl` (iPhone 17 Pro,
iOS 27.0, deleted afterwards), Debug build, input through `axe`. **Mock data
(layout only)** (`CMUX_MOBILE_MOCK_AUTH=1`): sample user, teams and Macs; layout and
copy are real. Stills only (no motion this round). The 1-minute load average
was 35.1 at the start; another session pushed it to 53 to 67 during the later
stills, which does not affect stills.

| File | Shows |
| --- | --- |
| `img/14-remove-alert-per-row.png` | Swipe 91C7, then the centered alert (no arrow) for 91C7, 3F2A and mini 4: each names the swiped Mac |
| `img/10-one-tag-rule-workspaces-and-devices.png` | Workspaces (Personal): empty state and filter menu say "Aziz's MacBook Pro 3F2A" / "91C7"; Devices shows the same tags as capsules |
| `img/08-live-type-change-account.png` | Account at Large, then AX5 changed while running (name, "Email code" and envelope grow), then back |
| `img/A-last-seen-one-formatter.png` | MacBook Pro: folded row, filter menu and Devices all say "Last seen 2h ago" |
| `img/BCD-polish.png` | Devices bottom with no empty Phones section; team page titles on one x; editor preview pinned (48 pt) above the emoji keyboard |
| `screens/*.png` | All captures |

Not captured: a folded Workspaces row with a tag capsule (the sample
workspaces are all on Manaflow's Macs, which have unique names). Covered by
code and by `MacNamesAgreementTests`.
