# C++ terminal frontend

This standalone C++20 consumer uses only the strict public resource API. It
selects a terminal by opaque `TerminalId`, reads its typed screen, history, and
lifecycle, opens a typed terminal attachment, reduces snapshot, patch, and
scroll items into a screen, and cancels the stream deterministically.

With `--command`, it launches a shell command in the current or selected
workspace. Stable correlation and idempotency keys recover the exact
`CreatedTerminalPath` if the `workspace.run` response is lost. After the
attachment ends, `terminal.wait_exit(0)` and `terminal.refresh()` expose and
cross-check the durable exit outcome. The initial history read uses validated
styled-history options, and the attachment uses the typed read-only flag.

From the cmux checkout root:

```sh
cmake -S cmux-tui/bindings/examples/cpp-terminal-frontend -B /tmp/cmux-cpp-terminal-frontend
cmake --build /tmp/cmux-cpp-terminal-frontend --parallel
/tmp/cmux-cpp-terminal-frontend/cmux-cpp-terminal-frontend --session main
```

Select an existing terminal:

```sh
/tmp/cmux-cpp-terminal-frontend/cmux-cpp-terminal-frontend \
  --terminal term_0123456789abcdef0123456789abcdef
```

Launch and observe a command:

```sh
/tmp/cmux-cpp-terminal-frontend/cmux-cpp-terminal-frontend \
  --command 'cargo test --workspace' \
  --cwd "$PWD"
```

`--workspace WORKSPACE_ID` targets a specific workspace. Callers that persist
an operation across process restarts can provide `--correlation-key` and
`--idempotency-key`. `--cols`, `--rows`, and `--poll-ms` control the viewer and
bounded stream poll. SIGINT and SIGTERM release the viewer, cancel the stream,
and then read the terminal's exact exit state.

Run the deterministic injected-transport tests with:

```sh
ctest --test-dir /tmp/cmux-cpp-terminal-frontend --output-on-failure
```

The tests compile with `-Wall -Wextra -Wpedantic -Werror`. They cover opaque
terminal selection, typed render reduction, pre-ack stream items, unknown
variants, viewer resize and release on the attachment connection,
end-before-response cancellation, typed screen and styled-history reads,
running-to-exited lifecycle, exact exit code 17, and creation recovery after a
dropped mutation response.

The CMake project defaults `CMUX_CPP_SDK_DIR` to the adjacent local SDK. To
consume an installed SDK, configure with `-DCMUX_CPP_SDK_DIR=` and provide its
installation prefix through normal CMake package discovery.
