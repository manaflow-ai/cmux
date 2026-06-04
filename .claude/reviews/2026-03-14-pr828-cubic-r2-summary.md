# Review Loop Summary — PR #828 Cubic Issues (Round 2)

**Date:** 2026-03-14
**Rounds:** 2/3
**Status:** Converged (zero new findings in Round 2)
**Reviewers:** Security(opus) + Logic(opus) + Completeness(opus)

## Issues by Round
| Round | Reviewers | Found | Fixed | Skipped | Cross-validated |
|-------|-----------|-------|-------|---------|-----------------|
| 0     | cubic     | 11    | 6     | 5       | -               |
| 1     | 3         | 2     | 2     | 0       | 2               |
| 2     | 1         | 0     | -     | -       | Converged       |

## Cubic Issues Disposition (11 total)

### Fixed (8):
1. **callbacks.rs** - All 6 FFI trampolines wrapped with `catch_unwind` + panic logging (P1)
2. **v2.rs:560** - `surface.send_input` UUID validation added (P1, cross-validated in R1)
3. **v2.rs:622** - `notification.create` UUID validation added (P2)
4. **window.rs:62** - `lock().unwrap()` → `lock_or_recover` (P2)
5. **window.rs:280** - Additional `lock().unwrap()` found by reviewers (cross-validated, elevated to high)
6. **main.rs:90** - `wrap` bool flag fixed with `action = Set, default_value_t = true` (P2)
7. **demo.sh:66** - Non-socket file check added (P2)
8. **demo.sh:120** - nc timeout `-w 5` added (P2)

### Skipped with rationale (3):
- **server.rs:70** - Already fixed in prior round (stale socket detection is correct)
- **app.rs:45 RuntimeCallbacks** - False positive (callbacks stored in `state._callbacks`)
- **store.rs:24 dead code** - Intentional MVP scaffolding

### Not in scope (medium, no fix needed):
- **build.rs:164** - `.flatten()` in build script is acceptable
- **GHOSTTY_APP_PTR lock().unwrap()** - Static mutex for raw pointer; crash-on-poison is safer than recovery

## Changes Made
```
 linux/cmux-cli/src/main.rs         |  6 ++-
 linux/cmux/src/socket/v2.rs        | 46 ++++++++++++++----
 linux/cmux/src/ui/window.rs        | 14 +-----
 linux/ghostty-gtk/src/callbacks.rs | 98 ++++++++++++++++++++++++-
 scripts/capture-linux-port-demo.sh |  8 +++-
 5 files changed, 110 insertions(+), 62 deletions(-)
```

## Build Verification
- `cargo check`: pass (26 pre-existing dead code warnings, no new warnings)
