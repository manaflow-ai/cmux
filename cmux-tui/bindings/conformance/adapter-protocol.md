# Public resource adapter protocol

Each adapter imports only its handwritten SDK root. It reads one UTF-8 JSON
object from standard input, writes one UTF-8 JSON object, and exits.

Input:

```json
{
  "contract_version": 2,
  "id": "case-id",
  "op": "read",
  "socket_path": "/tmp/conformance.sock",
  "constants": {}
}
```

Success:

```json
{"contract_version":2,"id":"case-id","ok":true,"value":{}}
```

An adapter failure uses `ok: false` with a stable `kind` of `adapter`,
`transport`, `protocol`, or `resource`. Expected protocol errors are
successful observations returned as normalized values.

Supported fake-peer operations are `read`, `mutation-replay`,
`mutation-error`, `stream-unknown`, `stream-cancel`, `stream-overflow`,
`redaction`, `creation-resolve`, `creation-conflict`, and
`terminal-wait-exit`. Live operations are `live-setup`,
`live-creation-exit`, `live-exit-restart`, and `live-restart`. All network
operations must use public resource handles. An adapter may normalize public
value types, but it must not construct resource protocol envelopes itself or
import the raw/generated API.

`creation-resolve` calls `session.creation.resolve` with
`constants.correlation_key`. It returns every field present in the typed
`CreationResolution`, converts IDs to strings, and converts revisions to
decimal strings. It omits absent optional fields. The fixtures exercise:

```text
created: workspace, terminal, and browser CreatedPath variants
pending: recovery wait
not_applied: retry_same_idempotency_key and retry_new_idempotency_key
indeterminate: recovery do_not_retry
```

`creation-conflict` calls `workspace.create` on `constants.session` with
`name=constants.name`, `initial_content=empty`,
`correlation_key=constants.correlation_key`, and the explicit mutation key
`constants.idempotency_key`. The expected `creation.conflict` is returned as
the same normalized error value used by `mutation-error`.

`terminal-wait-exit` selects `constants.terminal` directly below
`constants.session`, parses the input decimal-string `timeout_ms`, and calls
`terminal.wait_exit`. It returns the exact typed union:

```text
pending: state, terminal_id, lifecycle, revision
exited:  state, terminal_id, lifecycle, outcome, exited_at, revision
```

IDs are strings. `revision` and `exited_at` remain decimal strings. Exit-code
outcomes retain the integer code, including 17.

`live-setup` creates one stable workspace, renames it, creates two workspaces
with the same exact name, and attempts a name-selected rename. The adapter
must observe `selector.ambiguous`, preserve both candidate IDs, and prove the
failed mutation changed neither duplicate. Its exact value fields are:

```text
pinged, stable_id, stable_renamed, duplicate_ids, ambiguity_code,
ambiguity_preserved_all_candidates, no_mutation
```

`live-creation-exit` receives:

```text
expected_stable_id, exit_shell, pending_timeout_ms, exit_timeout_ms,
expected_exit_code
```

The stable workspace is intentionally empty. The adapter first calls
`screen.create` in it with idempotency key
`<key_prefix>-runtime-screen`, then uses the returned pane for `pane.run`.
That run executes `exit_shell` with idempotency key
`<key_prefix>-terminal-run` and correlation key
`<key_prefix>-terminal-correlation`. It must then call, in order:

1. `terminal.wait_exit(pending_timeout_ms)`, which must return pending.
2. `session.creation.resolve(correlation_key)`, which must return the same
   terminal path with state created and recovery none.
3. `terminal.wait_exit(exit_timeout_ms)`, which must return exit code 17.

Its exact value fields are:

```text
correlation_key, created_path, pending_terminal_id, pending_state,
pending_lifecycle, creation_state, creation_recovery, creation_generation,
creation_revision, exit_state, exit_terminal_id, exit_lifecycle, exit_kind,
exit_code, exited_at, exit_revision
```

`created_path` is the normalized terminal `CreatedPath`. All revisions and
timestamps are decimal strings.

The runner stops the server process and starts the exact same binary with the
same session and durable state root. `live-exit-restart` receives:

```text
expected_created_path, expected_correlation_key,
expected_creation_generation, expected_creation_revision,
expected_exited_at, expected_exit_revision, exit_timeout_ms,
expected_exit_code
```

It resolves the correlation key again, selects the terminal directly by the
expected terminal ID, and calls `terminal.wait_exit(exit_timeout_ms)`. Its
exact value fields are:

```text
correlation_key, created_path, creation_state, creation_recovery,
creation_generation, creation_revision, exit_state, exit_terminal_id,
exit_lifecycle, exit_kind, exit_code, exited_at, exit_revision
```

Every value must match the first process. This proves the creation path and
exit record are durable. `live-restart` then receives the three expected
workspace IDs, verifies their IDs and names survived, closes them by ID, and
proves they disappeared. Its exact value fields are:

```text
same_ids, stable_name_preserved, duplicates_preserved, closed, disappeared
```

Every live mutation key is derived from `key_prefix`: `stable-create`,
`stable-rename`, `duplicate-a`, `duplicate-b`, `ambiguous-rename`,
`runtime-screen`, `terminal-run`, `close-stable`, `close-a`, and `close-b`.
TypeScript runs every phase over Unix and WebSocket transports. The other
handwritten SDKs currently run them over Unix.
