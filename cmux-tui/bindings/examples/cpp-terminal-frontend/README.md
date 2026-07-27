# C++ terminal frontend

This standalone C++20 consumer uses only the public local C++ SDK. It connects
to a cmux-tui Unix socket, checks protocol 10 and `attach-initial-size`, fetches
the workspace tree, selects the active live PTY, reports an initial grid, and
opens a typed render attachment.

The in-memory screen replaces every row from `render-state`, patches indexed
rows from `render-delta`, tracks `scroll-changed`, and stops on `detached`.
Overflow and transport failure close both connections, discard the cached
screen, reconnect, and require a fresh `render-state` before accepting deltas.
SIGINT and SIGTERM close the render and control transports.

From the cmux checkout root:

```sh
cmake -S cmux-tui/bindings/examples/cpp-terminal-frontend -B /tmp/cmux-cpp-terminal-frontend && cmake --build /tmp/cmux-cpp-terminal-frontend --parallel && /tmp/cmux-cpp-terminal-frontend/cmux-cpp-terminal-frontend --session main
```

Use `--socket PATH` for an explicit Unix socket, `--surface ID` for a specific
live PTY, `--cols N --rows N` for the initial grid, and `--reconnects N` to
change the retry limit.

Run the deterministic injected-transport tests with:

```sh
ctest --test-dir /tmp/cmux-cpp-terminal-frontend --output-on-failure
```

The CMake project defaults `CMUX_CPP_SDK_DIR` to the adjacent local SDK. To
consume an installed SDK, configure with `-DCMUX_CPP_SDK_DIR=` and provide its
installation prefix through normal CMake package discovery.
