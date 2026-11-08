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

The v2 endpoint exposes one local machine and session. The consumer still
validates their typed IDs instead of treating user labels as identity.

1. **E1:** Names are intentionally non-unique, but `find_*_by_name()` returns an
   ordinary list. Every automation consumer needs the same zero, one, or many
   guard before converting a match to an ID selector.
2. **E2:** Observing a synchronous event stream while issuing mutations still
   needs a reader thread. `stream.next(timeout=...)` bounds a read but does not
   multiplex it with application work.
3. **E3:** Mutation revisions are decimal strings even though Python integers
   retain
   uint64 exactly. Consumers manually carry those strings from each receipt to
   the next `expected_revision`.
4. **E4:** Correlation lookup makes create recovery exact, but the application
   still owns polling and backoff for `pending`, plus the bounded retry decision
   for `not_applied`.

`Client.with_request_options()` already separates a one-call local deadline
from a terminal operation timeout.
