# Zig SDK friction

The example used only `cmux.Client`, `cmux.Limits`, `cmux.Field`, and generated
declarations under `cmux.protocol`. It did not use a raw call, private
declaration, handwritten wire encoding, or SDK transport adapter.

## Prioritized improvements

1. Add a provider-scoped client. It should own and zero the authority, run
   `identify`, require `provider-managed-workspace-authority-v2`, mark the
   generation, and expose `snapshot`, `create`, `rename`, and `close`. The
   example currently implements this lifecycle itself.

2. Return structured remote failures. Every command collapses server rejection
   to `error.RemoteError`; callers must immediately read
   `Client.lastRemoteError()`. This forced a two-phase `connect` then
   `initialize` API so an authority failure did not destroy the client and its
   diagnostic message.

3. Enforce generated command metadata in the client. Generated provider
   methods can be called without identifying the server, checking protocol 9,
   checking the provider capability, or selecting a provider-authority
   profile. The example manually gates all four assumptions.

4. Add revision and idempotency fields to provider rename and close in the
   protocol. `create-workspace` carries generation, revision, origin, and
   mutation id. Provider rename and close carry none of them. A local revision
   check cannot prevent another controller from committing between the check
   and request, and a lost response cannot be retried exactly once.

5. Add `hasCapability` and `requireCapability` helpers. Consumers currently
   scan `IdentifyResult.capabilities` and duplicate command-specific error
   choices.

6. Provide an owned topology conversion helper. `Decoded(Tree)` has a clear
   arena lifetime, but a long-lived controller must manually deep-copy every
   workspace key and name before deinitializing the result.

7. Zero sensitive request buffers. The example overwrites its owned authority
   on cleanup, but generic request encoding temporarily copies the authority
   into arenas and output buffers that are freed without explicit overwrite.

8. Offer concise optional-field construction. A durable create requires six
   repetitions such as `cmux.Field([]const u8).some(value)`. Request builders
   could preserve absent-versus-null semantics while reducing type noise.

## Useful existing behavior

- Native `u64` preserves revisions and ids without conversion.
- Every decoded call result has explicit `deinit`, and allocator leak checking
  passed for the complete handshake and topology copy.
- Synchronous request borrowing makes stack and argument slices safe through a
  call.
- Unix socket paths and transport limits are public options.
- Generated provider request and result types matched the protocol exactly.
