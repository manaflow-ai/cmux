# Go SDK consumer friction

1. `Workspace.Run` returns a complete typed `CreatedPath`, so the old numeric
   tree and surface joins are gone. Building the corresponding terminal handle
   still requires spelling every ancestor selector.
2. `Terminal.Wait`, `ReadScreen`, and `ReadHistory` return `Document`. The bot
   must validate the conventional `text` field and parse its completion marker
   at runtime.
3. `Terminal.Wait` is bounded by the client's request timeout as well as its
   operation timeout. The bot must keep the client timeout longer than the
   terminal wait timeout.
4. The resource client intentionally does not retry mutations. A production
   bot must decide how to recover from an indeterminate workspace creation or
   run request using its idempotency key.
5. `Agent.Report` is available only from an `Agent` returned by `agent.list`.
   A new terminal cannot directly report its first agent state through the
   session or terminal handle.
6. The client accepts `context.Context` throughout, but cleanup after parent
   cancellation still needs a fresh bounded background context.

The consumer imports only the public Go package. It uses no `raw` subpackage,
generic request method, private wire package, `Extra` option map, or legacy
numeric ID/tree/event model.
