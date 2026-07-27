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

`CmuxClient.builder().build()` uses `CMUX_TUI_SOCKET` when set, then legacy
`CMUX_MUX_SOCKET`, then the default session socket path.

## E2E

```bash
cd cmux-tui/bindings/java
CMUX_TUI_SOCKET=/path/to/session.sock scripts/build.sh
CMUX_TUI_SOCKET=/path/to/session.sock java -cp out com.cmux.E2e
```
