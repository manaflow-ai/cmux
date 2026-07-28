# Java SDK friction

No raw or private API was used.

Resolved during this simulation: `TerminalPlacement.lifecycle` is required but
nullable in the schema. The initial generated decoder rejected the JSON null
returned by ordinary local `createTerminal` calls. The generator and regression
test now preserve null, and this fake server exercises that response.

1. A common isolated-task flow requires coordinating `createWorkspace`,
   `createTerminal`, marker injection, repeated `readScreen`,
   `readScrollback`, `notify`, and `closeWorkspace`. A
   `runCapturedInWorkspace` helper with cleanup and exit status would remove
   the largest source of application code.
2. Generated `waitFor` uses the command connection and shares its transport
   timeout. The protocol command can outlive that deadline and blocks other
   requests. A dedicated cancellable wait handle or client-managed secondary
   connection would make automation safe.
3. The SDK exposes no terminal exit-status primitive. Consumers must inject a
   unique marker into PTY output, parse it, and keep the wrapper alive long
   enough to capture the viewport. A typed terminal-completed event or
   `waitForExit` result should include status and retained output.
4. Optional generated fields use `Field<T>`, while builders accept nullable
   values where `null` means explicit JSON null and skipping the method means
   omission. Builders should expose named `omitX` and `nullX` methods, or
   document nullability on every setter.
5. Request builders do not validate cross-field rules such as `argv` versus
   `command`, `workspace` versus `key`, or paired `cols` and `rows`. Invalid
   combinations fail only after a socket round trip.
6. Cleanup requires a custom synchronized guard plus a shutdown hook. A closeable
   workspace lease would make ownership and idempotent cleanup explicit.
7. Styled scrollback is useful, but converting `RenderRow` and `RenderRun` to
   plain text and paging beyond 65,535 rows is consumer work. Add
   `plainText()` and an iterator or pager.
8. `CmuxCommandException` provides a message and request id without a stable
   error code. Automation cannot reliably distinguish a timeout, missing
   surface, revision conflict, or permission failure without parsing prose.
