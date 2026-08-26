# Adapter protocol

Each adapter reads one UTF-8 NDJSON object from standard input and writes one
UTF-8 NDJSON object to standard output. The process exits after the response.

Every request contains:

```json
{"contract_version":1,"id":"case-id","op":"identify"}
```

Every successful response contains the same contract version and ID:

```json
{"contract_version":1,"id":"case-id","ok":true,"value":{}}
```

Failures use a stable error category:

```json
{"contract_version":1,"id":"case-id","ok":false,"error":{"kind":"decode","message":"..."}}
```

Allowed categories are `timeout`, `limit`, `command`, `decode`, and
`transport`. Protocol `uint64` values in normalized adapter output are
decimal strings.

Operations are `metadata`, `identify`, `nullable-literal`,
`optional-nullable-request`, `required-nullable-event`,
`optional-non-null-response`, `optional-non-null-event`, `stream`,
`close-pending-stream`, `authority`, `authority-denied`, and `real-flow`.
Adapters must call public typed SDK methods. The presence operations expose
whether public types preserve the schema's missing, null, and value
boundaries. The harness supplies literal fixture objects without consulting
generated schema data. `metadata` must use public generated inventory.
`authority-denied` uses the default client, catches the SDK's typed local
authority error, and reports `{"denied":true}`; the harness independently
asserts that the fake server received no bytes. `authority` opts into provider
authority only for its positive provider case.

`real-flow` runs against an isolated ephemeral server. It identifies the
server, subscribes to delta events, creates a named workspace and PTY,
sends a marker, waits for and reads the marker, renames and closes the
workspace, checks delta ordering, and confirms the workspace disappeared.
Socket framing, timing, malformed bytes, and expected wire requests belong
to the harness, not to adapters.
