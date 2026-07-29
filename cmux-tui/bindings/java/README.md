# cmux Java SDK

This dependency-free Java 17 SDK exposes the `cmux.protocol/1` resource API.
Typed handles cover machines, sessions, workspaces, screens, panes, tabs,
terminals, browsers, connected clients, pairing requests, projections,
notifications, agents, sidebar views, and providers.

The legacy protocol-v10 API remains available under `com.cmux.raw`.

## Build and test

```bash
cd cmux-tui/bindings/java
scripts/test.sh
```

The build produces `build/cmux-java-sdk.jar`. Maven metadata is also included:

```bash
mvn -q package
```

## Resource API

```java
try (Client client = Client.builder().build()) {
    Machine machine = client.machine(Selector.current());
    Session session = machine.session(Selector.current());
    Workspace workspace = session.workspace(Selector.current());

    MutationResult<CreatedPath> created = workspace.run(
        Options.Run.builder(ExactCommand.of("printf", "hello\n")).build()
    );
    Terminal terminal = session.terminal(
        Selector.id(created.value().terminal().orElseThrow())
    );
    System.out.println(terminal.readScreen(Options.Read.defaults()).fields());
}
```

`ExactCommand` preserves every argument without shell interpretation.
`ShellCommand` requests explicit server-side shell execution. Resource handles
perform no I/O when copied and never implement `AutoCloseable`.

Only `Client` and `ResourceStream` own transport state. Use try-with-resources
for both:

```java
try (ResourceStream<TerminalAttachmentItem> stream =
        terminal.attach(new Options.TerminalAttach(
            Options.Stream.defaults(),
            Optional.empty(),
            Optional.empty(),
            true
        ))) {
    StreamItem<TerminalAttachmentItem> item = stream.next();
}
```

Mutations receive an idempotency key generated from 128 bits of secure random
data unless the caller supplies one. The client never retries mutations.
`Decimal` preserves the full unsigned 64-bit range as a canonical JSON string.
`Secret`, `ProviderCredential`, and `RendererGrant` redact credential material
from normal string formatting.

`Client.Builder.transport(...)` accepts an injected transport for WebSockets,
non-Unix platforms, and tests. Without one, the SDK connects to the discovered
Unix session socket.

## Raw API

Existing protocol-v10 callers can migrate imports without changing behavior:

```java
import com.cmux.raw.CmuxClient;
import com.cmux.raw.IdentifyResult;

try (CmuxClient client = CmuxClient.builder().build()) {
    IdentifyResult server = client.identify();
    System.out.println(server.protocol());
}
```
