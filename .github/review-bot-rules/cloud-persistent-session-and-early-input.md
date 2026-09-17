# Cloud Persistent Session and Early Input

Apply this rule to Cloud terminal creation, persistent cmux-tui transport, manual mirror panes, and terminal runtime admission.

## Fail

- Spawn a new `cmux-tui` client, CLI process, authenticated carrier, or event socket for each control request, split/tab, snapshot, or event subscription when the machine-owned persistent session can multiplex it.
- Route control requests and revisioned events over separate physical transports without a documented protocol or isolation requirement. Independent logical terminal streams over one carrier are allowed when they preserve attachment leases, cancellation, geometry ownership, and byte routing.
- Make the user wait for remote PTY creation, shell startup, snapshot refresh, or terminal attachment before inserting the local manual pane or starting its empty Ghostty runtime.
- Drop or retarget input typed during the local pane, renderer, or remote attachment transition. Preserve authored input order and the surface identity that owns key down, key repeat, key up, cancellation, and reconnect.
- Replace a current validated event graph with an unconditional full snapshot on every Cmd-D/Cmd-T path, or remove idempotency keys, auth checks, revision fences, attachment leases, or fail-closed identity resolution to save time.

## Pass

- One authenticated machine-owned carrier and one persistent control connection multiplex control replies and ordered events. Logical per-terminal streams remain scoped when the protocol needs independent leases or cancellation.
- A reservation starts the local empty manual Ghostty runtime immediately, then remote creation and attachment populate it. The remote operation still uses the existing auth, durable mutation key, revision, and attachment checks.
- Snapshot refresh is limited to cold, stale, missing, or revision-conflict state. Current validated event state is reused.
- Tests and latency evidence identify local runtime admission, remote creation, attachment, shell startup, and visible command output separately. Do not claim a theoretical minimum from one path or add fixed sleeps to make a race disappear.

## Report

When this rule fails, name the extra client, transport, snapshot, or readiness gate, explain which auth/identity/input invariant it risks, and suggest the smallest owner-based fix.
