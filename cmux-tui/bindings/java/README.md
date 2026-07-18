# cmux Java Client

Java 17 client for the cmux-tui Unix-socket JSON-lines protocol. The build is
javac-only and uses a small vendored JSON parser/serializer in the package.

## Build

```bash
cd cmux-tui/bindings/java
scripts/build.sh
java -cp out com.cmux.JsonTest
```

On a machine without a local JRE:

```bash
docker run --rm -v "$PWD":/w -w /w eclipse-temurin:17 bash -lc 'scripts/build.sh && java -cp out com.cmux.JsonTest'
```

## Usage

```java
try (CmuxClient client = CmuxClient.builder().build()) {
    IdentifyResult info = client.identify();
    SurfaceResult surface = client.newWorkspace(
        NewWorkspaceRequest.builder().name("sdk-demo").cols(80).rows(24).build());
    client.send(surface.surface(), "echo hello\r");
    System.out.println(client.readScreen(surface.surface()).text());
}
```

`client.processInfo(surface.surface())` returns the daemon-owned PID, exact
argv list, current cwd, and canonical PTY name.

On the trusted local socket, `client.ensureTerminal(...)` creates or reconnects
one stable terminal UUID. `EnsureTerminalRequest.Builder.waitAfterCommand(true)`
retains its final VT state after child exit until explicit close and is
creation-only.
`client.reparentTerminal(...)` moves the same identity without replacing its
PTY or child process.

## Protocol v8 topology

```java
TopologySnapshot snapshot = client.topologySnapshot();
TopologySubscribeOutcome outcome = client.subscribeTopology(snapshot.cursor());
if (outcome instanceof TopologySubscription subscription) {
    try (subscription) {
        TopologyStreamEvent event = subscription.next(Duration.ofSeconds(5));
        if (event instanceof TopologyDelta delta) {
            System.out.println(delta.revision());
        }
    }
} else {
    snapshot = client.topologySnapshot();
}
```

Immutable records use `java.util.UUID`. `IdentifyResult.topologyCursor()` uses
`canonicalTopologyRevision`; `topologyRevision` remains the legacy tree
revision. Capability, authority, and adjacent-revision failures return the
sealed `TopologySubscribeOutcome` recovery case and close the stream.
`ping()` returns immutable liveness and authority data.

`CmuxClient.builder().build()` uses `CMUX_TUI_SOCKET` when set, then legacy
`CMUX_MUX_SOCKET`, then the default session socket path.

Default derivation uses `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`; empty values are ignored. On Darwin, paths over 103 filesystem bytes fall back to `/tmp/cmux-tui-<uid>` and are never truncated.

## E2E

```bash
cd cmux-tui/bindings/java
CMUX_TUI_SOCKET=/path/to/session.sock scripts/build.sh
CMUX_TUI_SOCKET=/path/to/session.sock java -cp out com.cmux.E2e
```
