# Python SDK consumer friction

Production code uses only `cmux.Client`, resource handles, typed IDs,
snapshots, options, events, receipts, and public errors. Raw JSON exists only
in the deterministic fake server.

## Correctness blockers

These do not prevent the example from running. They prevent a robust
unattended CI orchestrator.

1. **P0, create recovery:** Create operations have no durable caller
   correlation key. A unique workspace name can reconcile one
   `workspace.create`, but concurrent same-name creates are ambiguous.
   Anonymous `screen.create`, `pane.create`, and `pane.split` are worse because
   their indeterminate `CreatedPath` contains several server-allocated IDs.
   The example refuses to retry those operations.

   Smallest language-neutral contract change: accept a `correlation_key`
   distinct from the per-attempt idempotency key, store it atomically with the
   creation, and expose a lookup returning the original full `CreatedPath` and
   committed revision. Retried attempts use new idempotency keys and the same
   correlation key. Caller-allocated resource IDs are sufficient but not
   required; a unique, queryable correlation key provides the same recovery
   property with less ID-allocation surface.

2. **P0, command completion:** `terminal.wait` reports regex match state and
   viewport text. It cannot report whether a command exited successfully.
   The durable terminal registry already distinguishes `running`, `exited`,
   and `tombstoned`, so it could support a reconnect-safe wait for lifecycle
   completion. Its current exit value contains only untyped reasons such as
   `host-exited`; the terminal host explicitly drops the child's authoritative
   exit status. Existing metadata therefore cannot support typed CI success or
   failure without marker parsing.

   Smallest language-neutral contract change: retain the child outcome at the
   terminal-host boundary, then add `terminal.wait_exit` returning typed
   lifecycle, exit code or signal, reason, exit timestamp, and revision. The
   existing retained exited terminal can supply final screen output through
   the normal read API.

3. **P1, orphan cleanup:** The API has no workspace lease, owner metadata, or
   expiry. A process killed before `workspace.close` leaves the environment
   behind. `--workspace-id` is only an application-level ownership assertion.

   Smallest language-neutral contract change: let `workspace.create` attach an
   owner key and renewable expiry, expose both in workspace snapshots, and
   close the workspace when its lease expires.

4. **P1, blocking-operation deadlines:** One client timeout bounds every
   request, including `terminal.wait`. A 60-second server wait on a client with
   the documented 10-second default fails after 10 seconds.

   Smallest language-neutral contract change: give blocking operations a
   per-call client deadline, or require generated clients to derive a transport
   deadline longer than the operation timeout. The example currently validates
   this relationship itself.

## Ergonomic gaps

1. **E1:** Selecting a session name across machines requires
   `list_machines()` and one
   `list_sessions()` call per machine. There is no client-level unique session
   resolver that returns candidate machine and session IDs on ambiguity.
2. **E2:** Names are intentionally non-unique, but `find_*_by_name()` returns an
   ordinary list. Every automation consumer needs the same zero, one, or many
   guard before converting a match to an ID selector.
3. **E3:** Synchronous stream iteration has no per-item timeout or nonblocking
   poll.
   The example needs a dedicated thread plus explicit stream cancellation to
   observe events while issuing mutations.
4. **E4:** The asyncio facade uses one worker for both blocking stream
   iteration and
   requests. Waiting for the next quiet stream item can prevent a mutation on
   the same async client from starting, so an async orchestrator needs another
   client or its own concurrency layer.
5. **E5:** `terminal.wait`, `terminal.read_screen`, `terminal.process`, and other
   document-shaped reads return `Document.fields` instead of typed result
   models. This example must validate `matched` and `text` at runtime.
6. **E6:** Mutation revisions are decimal strings even though Python integers
   retain
   uint64 exactly. Consumers manually carry those strings from each receipt to
   the next `expected_revision`.
7. **E7:** `MutationIndeterminateError` documents the recovery rule but has no
   inspect-and-retry helper. Each consumer must implement bounded inspection
   and choose which effects are safely correlatable.
8. **E8:** The Python README documents one `workspace.run` call but has no public
   resource-method inventory, selection recipe, event example, or
   indeterminate recovery example. The normative resource API specification
   is necessary to assemble this workflow.
