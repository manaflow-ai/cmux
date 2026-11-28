# Go SDK consumer friction

1. `Terminal.ReadScreen` exposes typed text directly. `ReadHistory` returns
   styled rows and runs, so this text-only bot still needs a small flattening
   helper.
2. `Terminal.WaitExit` is bounded by the client's request timeout as well as its
   operation timeout. The bot must keep the client timeout longer than the
   terminal wait timeout.
3. Create recovery is exact through a stable correlation key and
   `Session.ResolveCreation`, but application code still implements the bounded
   retry policy for `not_applied`, `pending`, and `indeterminate` states.
4. The client accepts `context.Context` throughout, but cleanup after parent
   cancellation still needs a fresh bounded background context.

The consumer imports only the public Go package. It uses no `raw` subpackage,
generic request method, private wire package, `Extra` option map, or legacy
numeric ID/tree/event model.
