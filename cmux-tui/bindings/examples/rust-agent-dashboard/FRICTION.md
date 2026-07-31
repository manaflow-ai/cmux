# Rust SDK consumer friction

## Findings fixed during the simulation

1. `ResourceSnapshot` now carries exact `AgentSnapshot` values with agent,
   terminal, state, source, and timestamp fields. One `session.snapshot` call
   replaces five filtered agent queries and one query per workspace.
2. Blocked notifications now target the agent's typed terminal ID.
3. Resource event upserts are typed `ResourceEntitySnapshot` variants, so
   consumers can apply known deltas without decoding protocol-shaped values.
4. All creation option types accept a validated correlation key.
   `session.creation().resolve` recovers the exact created path after an
   uncertain transport result.
5. `terminal.wait_exit` and `TerminalSnapshot` expose strict pending, running,
   exited, exit-code, signal, and unknown-outcome variants. The example checks
   the recovered terminal's durable exit without parsing terminal text.

## Remaining SDK friction

None found by this simulation.

## Application concerns

Reconnect timing, command correlation keys, idempotency keys, and how long to
wait for a terminal are application policy. The dashboard keeps those choices
explicit.

The consumer imports only the `cmux` crate root and uses no low-level protocol
client or private module.
