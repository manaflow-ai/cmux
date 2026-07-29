# Java CI orchestrator

This dependency-free Java 17 consumer creates an empty cmux workspace, runs a
shell task in a terminal, waits for a unique completion marker, captures the
screen and terminal history, posts an error notification when the task fails,
and closes the workspace.

The implementation imports only the public `com.cmux` resource API. It uses
typed machine, session, workspace, terminal, and notification handles.

## Test

From the cmux repository root:

```bash
cmux-tui/bindings/examples/java-ci-orchestrator/scripts/test.sh
```

The deterministic in-process server checks success, nonzero exit, timeout,
notification, opaque identifier routing, exact command arguments, and cleanup.
Compilation uses Java 17 with `-Xlint:all -Werror`.

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
screen and history. A nonzero status also creates an error notification and
becomes the process exit status. Transport or orchestration failures exit with
status `2`.

`CMUX_JAVA_SDK_JAR=/path/to/cmux-java-sdk.jar` compiles against an external SDK
artifact. Without it, the scripts build the adjacent local SDK.

The process installs a shutdown hook after connecting. Normal completion,
command failure, timeout, interruption, and JVM shutdown all attempt to close
the typed workspace handle.
