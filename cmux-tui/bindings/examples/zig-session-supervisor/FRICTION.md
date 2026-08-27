# Zig SDK friction

Production code uses no raw protocol, generated declaration, private symbol,
generic request, generic result escape, shell wrapper, or third-party package.
The fake server parses JSON only to verify the public SDK's wire behavior.

1. Names are user labels, not identities. Safe discovery requires listing each
   parent collection, matching exact names, and rejecting duplicates before
   retaining the typed ID.
2. Correlated recovery is precise but repetitive. Consumers must classify
   `RemoteError` and `MutationTransportUncertain`, inspect
   `session.creation.resolve`, apply its retry instruction, validate the
   operation and correlation key, and narrow `CreatedPath` to the expected
   shape. A typed `recoverCreate` helper per creation method would remove this
   policy duplication.
3. Direct `workspace.run` returns `CreatedTerminalPath`, while recovery returns
   the broader `CreatedPath` union. Applications must manually validate and
   narrow the recovered path.
4. Session streams correctly use dedicated connections and inherit the client
   timeout, but one timeout controls open, next, and cancel. Long-lived
   consumers often want separate connect, idle-read, and cancellation bounds.
5. Lists, mutations, resolutions, waits, and stream items own decoded storage
   independently. The explicit `deinit` contract is safe, but orchestration
   code has many short lifetimes and must copy any string it retains.
6. Terminal exit outcomes are forward compatible through
   `TerminalExitOutcome.unknown`, whose payload belongs to the wait result.
   A long-lived application must copy that payload or normalize it before
   deinitializing the result.

The implementation is principled because retries follow server recovery state,
resource IDs retain their types, commands remain exact argv, and streams remain
bounded and independently cancelable. The main SDK opportunity is a typed
correlated-create recovery combinator.
