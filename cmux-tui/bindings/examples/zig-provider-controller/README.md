# Zig provider controller

This Zig 0.15.2 example uses only the public `cmux_tui` API and Zig standard
library. It connects through a Unix socket, verifies the server identity and
provider capability, marks the mux generation as provider-managed, and copies
the returned topology into allocator-owned state.

The controller models workspace mutations with a cached generation and
workspace revision. `create-workspace` sends the server's
`expected_generation` and `expected_revision` compare-and-swap fields.
Provider rename and close have no wire revision guard, so the wrapper requires
the caller's expected revision locally and verifies that the returned revision
is contiguous.

Build and test from the repository root:

```sh
cd cmux-tui/bindings/examples/zig-provider-controller
zig version
zig build test
zig build
```

`zig version` must print `0.15.2`. The tests start a real, temporary Unix
socket server and cover the full provider lifecycle, stale revisions,
authority rejection, protocol and capability rejection, discontinuous
revisions, and allocator cleanup.

Set the pre-provisioned authority in the environment, then inspect a server:

```sh
export CMUX_PROVIDER_AUTHORITY='<provider-authority>'
zig build run -- /path/to/cmux-tui.sock inspect
```

Create a workspace with a canonical UUID key and stable mutation id:

```sh
zig build run -- /path/to/cmux-tui.sock create worker 22222222-2222-4222-8222-222222222222 mutation-create-1
```

Rename or close a provider-owned workspace:

```sh
zig build run -- /path/to/cmux-tui.sock rename 42 22222222-2222-4222-8222-222222222222 production
zig build run -- /path/to/cmux-tui.sock close 42 22222222-2222-4222-8222-222222222222
```

The controller owns its copied authority, registry id, generation, workspace
keys, and names. `deinit` closes the client, frees the topology, and overwrites
the authority buffer before freeing it. Public SDK call results remain
arena-backed and are deinitialized immediately after their data is copied.

Do not pass the authority as a command-line argument or print it. Environment
delivery is only a simple example boundary; production providers should load
the authority from their existing secret channel.
