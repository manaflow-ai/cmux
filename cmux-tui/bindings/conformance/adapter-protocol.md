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
`live-flow`. All network operations must use public resource handles. An
adapter may normalize public value types, but it must not construct resource
protocol envelopes itself or import the raw/generated API.
