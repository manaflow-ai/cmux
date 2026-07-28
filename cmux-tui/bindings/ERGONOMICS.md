# SDK ergonomics findings

The SDKs should generate the protocol wire surface and handwrite each
language's transport, lifecycle, errors, and conveniences. Seven standalone
consumers now exercise only public package APIs against deterministic servers.
This split keeps all 83 commands and 44 events synchronized without making the
public clients feel generated.

## Evidence from consumers

| Language | Consumer evidence | Improvement applied |
| --- | --- | --- |
| Python | The agent watchdog covers future events, reconnects, resubscription, notifications, and stale-agent timing over temporary Unix sockets. | Added `SurfaceContext`, strict active-PTY and surface lookup, render-row text, scrollback-tail reads, and pre-write authority and field checks. |
| Rust | The agent dashboard exercises snapshot bootstrap, delta events, agent polling, reconnects, and typed notifications as an independent Cargo package. | Added borrowed tree selectors, nullable accessors, provider-authority opt-in, and generated command and field checks. Generated output is deterministic without depending on the installed formatter. |
| TypeScript | The browser controller covers every browser command, state and frame streams, recovery, cancellation, and a clean DOM-only npm install. | Added a typed browser attachment with a lossless unknown-event variant, separate command and stream-idle timeouts, `AbortSignal`, authority profiles, and generated field checks. |
| Go | The terminal bot covers durable workspace ownership, stream reconnects, cancellation, cleanup, notifications, and identifiers near `uint64` limits. | Added context-preserving timeout errors, plain-text and scrollback-tail helpers, durable workspace discovery, a retryable `WorkspaceLease`, per-client limits, and pre-write authority and field checks. |
| Java | The CI orchestrator covers success, nonzero exit, timeout, cleanup, and compilation against the built jar. | Fixed required-nullable decoding, bounded pre-ack events, and added plain-text rendering, scrollback-tail reads, a retryable `WorkspaceLease`, authority profiles, and generated field checks. |
| C++ | The terminal frontend covers snapshot and delta rendering, resize ownership, recovery, and compilation against an installed CMake package. | Added a move-only render attachment that exposes its server client ID and routes sizing commands over the owning connection, plus authority profiles and generated command and field checks. |
| Zig | The provider controller covers authority, protocol, capability, revision, allocator, and secret-lifetime failures over a real temporary Unix socket. | Added `ProviderClient`, dedicated stream clients, owned remote errors, copied topology, revision checks, authority zeroization, and generated command and field checks. |

The simulations also exposed correctness defects that ordinary generated-shape
tests missed. Java and C++ now preserve a required nullable literal. Go
generated models preserve optional-nullable absence, null, and value, reject
missing required-nullable fields, and reject null for optional non-null fields.
TypeScript rejects missing required fields after applying negotiated version
and capability gates. Rust and Zig reject explicit null across all 47 optional
non-null fields. Java bounds events received before stream acknowledgement.
Go limit configuration is isolated per client. Installed-package tests cover
npm exports, Java jars, and CMake package discovery.

All seven typed clients now enforce generated command and present-field
protocol, capability, and provider-authority requirements before a guarded
write. Negotiation is lazy and cached. Deliberately named raw or unchecked
entrypoints remain available for forward-compatible protocol experiments.
The shared conformance matrix runs 266 public-API checks, including exact
request shapes and missing, null, and value cases for each presence category.

## Protocol work that SDKs cannot supply

- Agent state needs a protocol event. Polling `list-agents` is the only way to
  keep dashboards and watchdogs current in protocol 10.
- Terminal completion needs a typed exit status and retained final screen or
  scrollback boundary. Marker injection cannot be made race-free by a client
  helper.
- `send`, `notify`, provider rename, and provider close need request
  idempotency. Provider rename and close also need wire revision guards.
- Streams need sequence checkpoints and a resumable window before an SDK can
  promise byte-exact recovery after a disconnect.
- Remote failures need stable machine-readable codes for retry and conflict
  policy. Parsing server prose is not a safe compatibility contract.
- Browser frames need an encoding or media-type field before a client can
  select a decoder from the typed event.

## Remaining SDK-layer work

- Package subscription-before-snapshot, overflow resync, reconnect, and cache
  invalidation in a small lifecycle helper.
- Provide topology selectors and render reducers consistently across the
  languages that still require manual tree walks.
- Generalize captured-task helpers after the terminal completion protocol
  exists. Java and Go already expose retryable workspace leases.
- Make cancellation and command versus idle timeout behavior idiomatic in each
  blocking and asynchronous language.
- Add browser DOM keyboard and pointer adapters without adding a runtime
  dependency to the TypeScript package.

## Dependency policy

Python, TypeScript, Go, Java, C++, and Zig use only their standard library at
runtime. C++ applications inject their own WebSocket or TLS transport. Rust
uses `serde`, `serde_json`, and `libc`; these are narrow codec and Unix
integration dependencies rather than a client framework.

Code generation is a repository build tool, not a consumer dependency.
Published packages contain checked-in generated models plus handwritten public
clients. Development compilers, package builders, and fake-server harnesses
may use external tools, but those tools must not become runtime dependencies.
