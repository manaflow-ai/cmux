# Consumer friction

## Findings fixed during the simulation

1. The first isolated build failed because `cmux-sidebar` referenced
   `EnhancedKeyEvent`, which exists only in cmux's private Crossterm fork.
   Workspace builds masked the packaging defect. The crate now compiles against
   crates.io Crossterm 0.29 without a consumer patch.

2. `SidebarRuntime` originally reduced stream errors to display strings and
   clean ends to `closed`. It now exposes `SidebarRuntimeState::Ended` with the
   complete `StreamEnd`, including gap reason, recovery directive, and cursor,
   plus `reattach()` for a fresh lease.

3. Applications that owned recovery had to duplicate the render reducer and
   widget. `SidebarModel::apply_item` and `SidebarWidget::new`, `block`,
   `without_block`, and `footer` are now public composition points. This
   example uses the runtime widget with an application-owned lifecycle footer.

## Remaining SDK friction

1. `SidebarRuntime` safely ignores an unknown typed event and reports its kind
   through `SidebarModel::status`, but it does not expose the preserved raw
   document to runtime consumers. An application that must log or inspect
   future payloads still has to own `SidebarViewStream` directly.

## Application concerns

1. Retry count and delay are product policy. This example allows three
   recoveries with a 100 ms delay.

2. The application owns terminal cleanup, quit and reload shortcuts, and the
   decision to retain the last frame while reconnecting.

3. Local queue overflow is treated like a gap: the companion runtime cancels
   the stale lease, then this application calls `reattach()` and waits for a
   full snapshot.
