# Java CI orchestrator

This dependency-free Java 17 consumer creates one isolated cmux workspace,
runs a shell task in a terminal inside it, polls the screen for a unique exit
marker, captures the live screen and styled scrollback as text, posts an error
notification when the task fails, and tombstones the workspace.

It uses only public typed SDK methods. It never calls `rawRequest`.

## Test

From the cmux repository root:

```bash
cmux-tui/bindings/examples/java-ci-orchestrator/scripts/test.sh
```

The deterministic integration test starts a fake Unix-socket cmux server and
checks successful, nonzero-exit, and timeout paths. Each path verifies the
typed command sequence and workspace cleanup.

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

The task string runs through `/bin/sh -lc`. Exit status `0` prints the captured
screen and scrollback. A nonzero task status also posts a typed
`NotificationLevel.ERROR` notification and becomes the process exit status.
Transport or orchestration failures exit with status `2`.

`CMUX_JAVA_SDK_JAR=/path/to/cmux-java-sdk.jar` compiles this example against an
external SDK artifact. Without it, the scripts build the adjacent local SDK.

The process installs a shutdown hook after connecting. Normal completion,
command failure, timeout, interruption, and JVM shutdown all attempt
`closeWorkspace` by the generated stable workspace key.

The fake server returns the ordinary local-terminal response with nullable
terminal identity and lifecycle fields, matching a non-durable local task.
