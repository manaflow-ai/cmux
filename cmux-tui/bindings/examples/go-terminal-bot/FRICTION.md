# Go SDK consumer friction

Production code uses only `cmux.Client`, generated request options and results,
typed events, `cmux.Stream`, exported errors, and base64 helpers. Raw JSON is
confined to the deterministic fake Unix server, where it implements the server
side and verifies public wire behavior.

## Correctness blockers

1. **P0: terminal completion has no typed status or retained-output boundary.**
   `surface-exited` has no exit status, and a local PTY is removed before that
   event. `ReadScreen` and `ReadScrollback` can therefore fail by the time a
   consumer learns that the task ended. This bot must inject an unpredictable
   marker, parse the byte attachment, and keep the wrapper alive for an
   acknowledgement before it can capture output. A `WaitTerminal` result with
   terminal ID, incarnation, lifecycle, exit status, final screen, and a
   retained scrollback handle would remove this protocol workaround.

2. **P0: context cancellation loses standard Go error identity.** Public
   command and stream methods convert `context.Canceled` and
   `context.DeadlineExceeded` into an SDK timeout error containing only the
   context error text. `errors.Is(err, context.Canceled)` and
   `errors.Is(err, context.DeadlineExceeded)` are false. The bot must inspect
   `context.Cause(ctx)` after every failed SDK call. The SDK error should
   unwrap the original context error while continuing to match
   `cmux.ErrTimeout`.

3. **P0: ambiguous delivery is unsafe for terminal input and notifications.**
   Durable workspace and terminal mutations have `origin` plus `mutation_id`,
   so this bot safely replays them after a lost response. `Send` and `Notify`
   have no idempotency key. A disconnect after the server commits either
   request leaves the caller unable to distinguish success from failure; the
   bot deliberately does not retry them. Request-scoped idempotency keys would
   make automation recovery deterministic.

4. **P1: byte attachments cannot resume from a stream checkpoint.** Reattach
   provides a new VT replay followed by new bytes, which restores terminal
   state but cannot continue a byte-exact application log. This bot treats the
   final typed screen and scrollback capture as authoritative after reconnect.
   A sequence number plus resumable output window, or a documented
   state-snapshot event distinct from raw output, would let consumers state
   exactly what continuity they provide.

## Ergonomic gaps

1. **P1: one timeout controls commands, handshakes, and idle stream reads.**
   A quiet task causes `RecvByte` and `RecvDelta` to return `ErrTimeout` at the
   client's command timeout even when both streams are healthy. The bot treats
   that as a reconnect. Separate connect, command, and stream-idle policies
   would avoid needless socket churn.

2. **P1: reconnect and resubscribe are entirely application-owned.** The bot
   recreates a client, identifies protocol 10, reopens each dedicated stream,
   handles overflow, and limits retries independently. A reconnecting stream
   with explicit `Disconnected`, `Resynced`, and terminal `Detached` outcomes
   would centralize the lifecycle contract.

3. **P1: remote command failures have no stable code.** `CommandError`
   preserves message and request ID, but an automation service cannot
   distinguish revision conflict, unknown surface, authorization failure, or
   validation failure without parsing English text. Stable error codes would
   let the bot refetch and retry compare-and-swap conflicts while rejecting
   permanent failures.

4. **P2: scrollback-tail capture requires a probe and manual rendering.**
   Consumers call `ReadScrollback(surface, 0, 0)` to learn `total`, calculate a
   second page, then concatenate every `RenderRun.Text`. A
   `ReadScrollbackTail` helper and `PlainText` method would remove repeated
   pagination and rendering code.

5. **P2: isolated task ownership is a large handwritten workflow.** A correct
   consumer coordinates subscription-before-snapshot, UUID generation,
   workspace discovery or guarded creation, terminal creation, agent reports,
   capture, notification, cancellation, and workspace tombstoning. A public
   workspace lease and captured-task helper could package these invariants
   while still exposing the underlying typed calls.

## Useful existing behavior

- `ID`, registry revisions, notification IDs, and event indexes remain
  `uint64`; the integration test preserves values near `math.MaxUint64`.
- Generated durable mutation options expose generation, revision, origin, and
  mutation ID without raw JSON.
- Subscribe and attach streams use separate connections, so reconnecting one
  does not block command calls or the other stream.
- Unknown events remain observable through `UnknownEvent` instead of being
  dropped.
