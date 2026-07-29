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

Supported operations are `read`, `mutation-replay`, `mutation-error`,
`stream-unknown`, `stream-cancel`, `stream-overflow`, `redaction`, and
the two-phase `live-setup` and `live-restart`. All network operations must use
public resource handles. An adapter may normalize public value types, but it
must not construct resource protocol envelopes itself or import the
raw/generated API.

`live-setup` creates one stable workspace, renames it, creates two workspaces
with the same exact name, and attempts a name-selected rename. The adapter
must observe `selector.ambiguous`, preserve both candidate IDs, and prove the
failed mutation changed neither duplicate. Its exact value fields are:

```text
pinged, stable_id, stable_renamed, duplicate_ids, ambiguity_code,
ambiguity_preserved_all_candidates, no_mutation
```

The runner stops the server process and starts the exact same binary with the
same session and durable state root. `live-restart` receives the three
expected IDs, verifies their IDs and names survived, closes them by ID, and
proves they disappeared. Its exact value fields are:

```text
same_ids, stable_name_preserved, duplicates_preserved, closed, disappeared
```

Every live mutation key is derived from `key_prefix`: `stable-create`,
`stable-rename`, `duplicate-a`, `duplicate-b`, `ambiguous-rename`,
`close-stable`, `close-a`, and `close-b`. TypeScript runs both phases over
Unix and WebSocket transports. The other handwritten SDKs currently run them
over Unix.
