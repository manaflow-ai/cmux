# Zig SDK friction

No raw protocol, generated declaration, private symbol, generic request, or
generic result escape is used.

1. `Client` exposes `providerScope(id)` but no typed provider-scope list. A
   controller must receive its provider scope ID from registration or durable
   state before it can use the resource API.
2. Provider workspace mutations require separate session and workspace IDs even
   though both belong to the same controller state. A provider-scoped workspace
   handle would preserve this relationship once.
3. Each owned mutation result must be deinitialized while borrowed snapshot
   strings remain live. Long-lived controllers must copy the generation and
   workspace name before deinitialization.
4. Revision sequencing remains application policy. The SDK sends an
   `expected_revision` and exposes structured conflict details, but it does not
   update a shared revision cursor across provider operations.
5. `renameWorkspace` models clearing the name as `?[]const u8`; `null` means
   explicit JSON null. A named `clearWorkspaceName` method would make this
   three-state behavior clearer at call sites.

The typed opaque IDs, provider-scope handle, revision preconditions, and
structured errors make the implementation principled. The local revision and
generation guard is application state, not a wire workaround.
