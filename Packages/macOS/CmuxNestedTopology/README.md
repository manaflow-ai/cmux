# CmuxNestedTopology

Provider-neutral nested topology model, Herdr socket adapter, secure
attachment lifecycle, read projection, capability-gated focus, session
restore semantics, reconnect scheduling, and RemoteHerdr session/window
mirroring for cmux (native Herdr nested-topology plan, including post–PR-6
mirroring helpers).

## Scope

This package owns:

- compound nested node IDs and immutable topology snapshots
- workspace / tab / pane / agent node values
- topology events and a validating pure reducer
- capability sets and connection-state values
- in-memory association, parent-map, and title-lock values
- provider-neutral ``NestedTopologyProviderClient`` (read + focus)
- ``HerdrNestedTopologyClient`` (newline-delimited JSON Unix socket; no `herdr` CLI)
- ``NestedReconnectScheduler`` for cancellation-aware reconnect backoff
- ``NestedTopologyAttachmentCoordinator`` — opt-in attachment lifecycle, endpoint
  security validation, host move/close hooks, plugin single-writer handoff,
  capability-gated ``focusNode``, and ``restoreFromIntent``
- **PR4 read projection**
  - ``NestedTopologyTwoPassRenderer`` / ``NestedTopologyReadService``
  - public read nodes + ``nested.topology.list`` JSON payload helpers
  - immutable ``NestedSidebarSubtreeSnapshot`` for sidebar mounting
  - cmux→client capability token ``nested_topology.read.v1``
- **PR5 focus**
  - ``NestedNodeFocusRequest`` / ``NestedNodeFocusResult``
  - Herdr `workspace.focus` / `tab.focus` / `pane.focus` / `agent.focus`
  - cmux→client capability token ``nested_topology.focus.v1``
  - control-socket method ``nested.node.focus``
- **PR6 restore**
  - versioned ``NestedAttachmentIntentDescriptor`` (intent only)
  - revalidate + identity compare + fresh snapshot on restore
  - disconnected + confirmation when identity proof is unavailable/mismatched
- **RemoteHerdr mirroring**
  - ``RemoteHerdrSessionMirror`` / ``RemoteHerdrWindowMirror`` / layout + sizing helpers
  - capability-gated pane I/O (`pane.send` / `split` / `resize` / `close` / `read`)

It does **not** persist nested node snapshots / output / credentials into session
manifests. Host AppKit wiring for ssh-tmux parity (real Bonsplit + Ghostty
panels, `remote.herdr.*`, `RemoteHerdrController`) lives in cmux `Sources/`
and executes the package verbs (`HostApply` / `SessionApply` / `Lifecycle` /
`PaneRoute` / `LiveApply`).

## Persistence and restore

Persist **attachment intent**, never live topology:

| Persisted | Not persisted |
|---|---|
| provider kind | nested node snapshot / tree |
| reattach policy | pane/agent output |
| non-secret endpoint locator (approved path) | tokens / bearer credentials |
| last verified provider instance ID (connection-scoped on protocol 17) | plugin association state files/records |
| last verified socket file identity | |

**Protocol 17 identity note:** Herdr protocol 17 does not advertise a durable
server instance id. ``NestedProviderInstanceID`` is minted per connection unless
the provider returns `instance_id`. The persisted “last verified provider
instance ID” therefore cannot prove continuity after reconnect on protocol 17;
unattended auto-reattach also requires a pinned socket file identity, and
otherwise restore leaves the attachment ``disconnected`` with
``pendingRestoreIntent`` until ``confirmPendingRestore``.

On `Workspace.restoreSessionSnapshot` (app wiring):

1. Wait until the terminal panel exists and stable surface identity is adopted.
2. Call ``NestedTopologyAttachmentCoordinator/restoreFromIntent``.
3. Re-run Unix-socket security checks and protocol compatibility.
4. Compare durable provider instance identity (and socket file identity).
5. Fetch a **fresh** `session.snapshot` — never rehydrate nodes from the manifest.
6. If identity proof is unavailable/mismatched: leave ``disconnected`` with
   ``pendingRestoreIntent`` and require ``confirmPendingRestore`` (explicit opt-in).

Gated by beta flag `nestedTopology.beta.enabled`. Host surface close cancels
in-flight restore without `server.stop` / child closes.

## Focus API (PR 5)

### Rules

1. Resolve host surface + attachment generation atomically before send.
2. Reject stale generation, wrong host, wrong kind, unsupported capability, or
   disconnected provider.
3. Forward typed JSON only — never synthesize keystrokes/shell when a method is
   unavailable.
4. Refresh/reconcile from provider events; do **not** invent optimistic topology
   from RPC success alone.

### Control socket (app-wired)

- Semantic capability: `nested_topology.focus.v1`
- Method: `nested.node.focus`
  - required: `host_surface_id`, structured `node_id`
  - optional: `expected_attachment_id`, `expected_provider_instance_id`
- Authorization: authenticated control-socket request ID (or UI `.userConfirmed`)
- Gated by beta flag `nestedTopology.beta.enabled`
- Worker-lane (not macOS/cmux focus-intent)

### Sidebar

Clicking a live nested row calls the same gated focus path when the beta flag
is enabled. Rows remain snapshot-boundary safe (immutable values + closures).

### Deferred action groups (next PRs)

- rename (must set/respect native-title lock)
- read / prompt / send input
- split / move / resize / layout
- close (with confirmation and explicit semantics)

## Read API (PR 4)

### Two-pass render

1. **Parent map** — ``NestedParentMap.replace(with:)`` from the snapshot (never
   re-inferred from titles each tick).
2. **Title locks** — ``NestedAssociationStore.proposeTitle`` suppresses overwrite
   when locked; the renderer diffs against last published labels so provider
   echoes do not thrash UI/socket consumers.

### Control socket (app-wired)

- Semantic capability: `nested_topology.read.v1` (additive `capabilities` array
  on `system.capabilities`)
- Method: `nested.topology.list` (optional `host_surface_id` / `host_workspace_id`)
- Default `system.tree` is unchanged (byte-compatible). Prefer
  `nested.topology.list` over extending the default tree; package helper
  ``NestedTopologyControlSocketPayload/foundationNestedTreeObject(attachments:)``
  exists if `include_nested` is wired later.
- Gated by beta flag `nestedTopology.beta.enabled` (same pattern as remote tmux)

### Sidebar

``NestedSidebarSubtreeSnapshot`` is an immutable value for expandable rows under
the host workspace/surface. Mount via app ``NestedSidebarSubtreeView``; rows must
not hold the attachment coordinator or other observable stores.

## Attachment lifecycle (PR 3)

``NestedTopologyAttachmentCoordinator`` is intended for app/window scope:

- Initial attach requires explicit ``NestedAttachmentAuthorization``
  (`.userConfirmed` or `.authenticatedControlSocket`). Environment/OSC may
  ``recordProposal`` only — proposals never authorize alone.
- Endpoint checks: absolute local Unix socket, `lstat` (final component must not
  be a symlink), current UID ownership, restrictive mode (`0600`), and
  device/inode identity recheck around connect.
- Host surface **move** preserves the attachment; **close** / teardown detaches
  without `server.stop` or child closes.
- When state becomes ``live``, a plugin single-writer handoff lock/env signal is
  acquired (``NestedPluginWriterHandoff``). Leaving `live` releases it so plugin
  fallback may resume.
- Default telemetry never includes socket paths or provider payloads.

## Herdr protocol 17 notes

Adaptation lives in ``HerdrProtocol17Compatibility``. Unknown JSON fields are
tolerated; missing required fields are errors.

Negotiated capabilities for protocol 17 include snapshot, events, and focus
(`topology.focus.v1`). Rename / input / split are not advertised until later PRs.

**Instance identity gap:** protocol 17 `ping` does not return a durable
server-lifetime `instance_id`. Until Herdr advertises one, the client mints a fresh
``NestedProviderInstanceID`` per successful connection and invalidates association
entries from prior generations on reconnect/resnapshot.

## Test

```bash
swift test --package-path Packages/macOS/CmuxNestedTopology
```

Adapter, attachment, read-projection, focus, and restore tests use temporary
Unix-socket fakes (or stubs) and do not require a live Herdr.

## Related

- manaflow-ai/cmux#8737
- cmux-herdr tracking: https://github.com/RaviTharuma/cmux-herdr/issues/11
- Upstream PR plan PR 1–6: model → adapter → attachment → read UI → focus → restore
- Native v1 complete per PARITY_MATRIX when restore revalidation lands (this PR)
