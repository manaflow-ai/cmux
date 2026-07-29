# cmux Java SDK

This dependency-free Java 17 SDK exposes the `cmux.protocol/1` resource API.
Typed handles cover machines, sessions, workspaces, screens, panes, tabs,
terminals, browsers, connected clients, pairing requests, projections,
notifications, agents, and sidebar views.

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

    MutationResult<CreatedTerminalPath> created = workspace.run(
        Options.Run.builder(ExactCommand.of("printf", "hello\n")).build()
    );
    Terminal terminal = session.terminal(
        Selector.id(created.value().terminalId())
    );
    Results.TerminalScreenResult screen =
        terminal.readScreen(Options.Read.defaults());
    System.out.println(screen.text());
}
```

`ExactCommand` preserves every argument without shell interpretation.
`ShellCommand` requests explicit server-side shell execution. Resource handles
perform no I/O when copied and never implement `AutoCloseable`.

Every operation returning `CreatedPath`, `CreatedTerminalPath`, or
`CreatedBrowserPath` accepts an optional validated `correlationKey` through
its typed creation options. The key is independent of the mutation
idempotency key and can be resolved later with `Session.resolveCreation(...)`.

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
    Optional<StreamItem<TerminalAttachmentItem>> item =
        stream.poll(Duration.ofSeconds(1));
}
```

Mutations receive an idempotency key generated from 128 bits of secure random
data unless the caller supplies one. The client never retries mutations. A
transport failure before a structured response throws
`MutationOutcomeUncertain`, which retains the exact operation and idempotency
key for state inspection. Interrupting a waiting thread cancels its local wait.
`ResourceStream.poll(Duration)` adds a bounded wait without ending or consuming
the stream when the bound elapses.

Known protocol objects reject unknown fields and malformed recognized union
variants. Open stream unions preserve an unrecognized variant as an immutable
`Unknown.raw()` object.

`Session.resolveCreation(...)` resolves a durable creation correlation key.
`Terminal.waitExit(...)` waits for process lifecycle state. It is separate
from `Terminal.waitFor(...)`, which matches terminal text.

`Screen.undoLayout(...)` requires the preview's confirmation token when
`confirmClose` is true. A `confirmation.required` error exposes typed
`ConfirmationRequiredDetails` through
`ResourceError.confirmationRequiredDetails()`.

`Decimal` preserves the full unsigned 64-bit range as a canonical JSON string.
`Secret` and `RendererGrant` redact credential material from normal string
formatting.

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
