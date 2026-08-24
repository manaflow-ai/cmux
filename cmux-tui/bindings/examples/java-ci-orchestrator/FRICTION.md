# Java SDK friction

No raw, generated-model, internal, private, or generic escape API is used.

The strict API resolved the earlier untyped result and exit-status gaps:
`terminal.waitExit`, `terminal.readScreen`, `terminal.readHistory`, terminal
lifecycle snapshots, and closed exit-outcome variants are all concrete types.
Creation methods accept correlation keys, deterministic terminal creation
returns `CreatedTerminalPath`, and `Session.resolveCreation` recovers a durable
created path after response loss.

Remaining friction:

1. `terminal.waitExit` shares the client's request deadline. The client timeout
   must exceed the server-side wait timeout, coupling connection policy to one
   operation.
2. `Session.resolveCreation` correctly returns the closed `CreatedPath` union,
   but a caller recovering a known operation must still verify the expected
   path variant at runtime.
3. Workspace ownership requires a custom shutdown hook and idempotent cleanup
   guard. An `AutoCloseable` workspace lease would make this lifecycle explicit.
4. Typed history preserves styled runs, so a plain-text CLI must concatenate
   runs and pages itself. A standard plain-text projection helper would avoid
   each consumer implementing this conversion.

The resource-handle composition, opaque identifiers, exact terminal lifecycle,
and correlation recovery are principled. No protocol workaround remains in the
command execution path.
