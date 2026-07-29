# Python SDK consumer friction

Production code uses only `cmux.Client`, resource handles, typed IDs,
snapshots, options, events, receipts, and public errors. Raw JSON exists only
in the deterministic fake server.

## Correctness gap

1. **P1, orphan cleanup:** The API has no workspace lease, owner metadata, or
   expiry. A process killed before `workspace.close` leaves the environment
   behind. `--workspace-id` is only an application-level ownership assertion.

   Smallest language-neutral contract change: let `workspace.create` attach an
   owner key and renewable expiry, expose both in workspace snapshots, and
   close the workspace when its lease expires.

## Ergonomic gaps

1. **E1:** Selecting a session name across machines requires
   `list_machines()` and one
   `list_sessions()` call per machine. There is no client-level unique session
   resolver that returns candidate machine and session IDs on ambiguity.
2. **E2:** Names are intentionally non-unique, but `find_*_by_name()` returns an
   ordinary list. Every automation consumer needs the same zero, one, or many
   guard before converting a match to an ID selector.
3. **E3:** Observing a synchronous event stream while issuing mutations still
   needs a reader thread. `stream.next(timeout=...)` bounds a read but does not
   multiplex it with application work.
4. **E4:** Mutation revisions are decimal strings even though Python integers
   retain
   uint64 exactly. Consumers manually carry those strings from each receipt to
   the next `expected_revision`.
5. **E5:** Correlation lookup makes create recovery exact, but the application
   still owns polling and backoff for `pending`, plus the bounded retry decision
   for `not_applied`.
6. **E6:** A terminal operation timeout and the local request deadline are
   independent. Long waits need an explicitly longer client or per-call
   deadline.
