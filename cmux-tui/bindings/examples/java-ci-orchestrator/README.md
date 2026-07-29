# Java CI orchestrator

This dependency-free Java 17 consumer creates an empty cmux workspace, runs a
shell task in a terminal, waits for its exact exit outcome, captures typed
screen and history results, posts an error notification when the task fails,
and closes the workspace.

The implementation imports only the public `com.cmux` resource API. It uses
typed machine, session, workspace, terminal, and notification handles. Stable
correlation and idempotency keys let it recover a created workspace or terminal
after a mutation response is lost.

## Test

From the cmux repository root:

```bash
cmux-tui/bindings/examples/java-ci-orchestrator/scripts/test.sh
```

The deterministic in-process server checks success, nonzero exit, bounded exit
waits, durable lifecycle snapshots, typed screen and styled-history decoding,
notification, opaque identifier routing, exact shell commands, cleanup, and
correlation recovery after a dropped `workspace.run` response. Compilation uses
Java 17 with `-Xlint:all -Werror`.

## Run

Build and run against a named local session:

```bash
cmux-tui/bindings/examples/java-ci-orchestrator/scripts/run.sh \
  --session main \
  --timeout-seconds 120 \
  --command 'cargo test --workspace'
```

Or select an explicit socket:

```bash
cmux-tui/bindings/examples/java-ci-orchestrator/scripts/run.sh \
  --socket "${CMUX_TUI_SOCKET:?CMUX_TUI_SOCKET is not set}" \
  --cwd "$PWD" \
  --command 'npm test'
```

The task string is sent as an explicit `ShellCommand`, so the target session
chooses its platform shell. Exit status `0` prints the captured screen and
history. A nonzero exit or signal creates an error notification targeted to
the task terminal and becomes the process exit status. Transport or
orchestration failures create a session-scoped notification and exit with
status `2`.

`CMUX_JAVA_SDK_JAR=/path/to/cmux-java-sdk.jar` compiles against an external SDK
artifact. Without it, the scripts build the adjacent local SDK.

The process installs a shutdown hook after connecting. Normal completion,
command failure, timeout, interruption, and JVM shutdown all attempt to close
the typed workspace handle.
