# cmux Java SDK

Dependency-free Java 17 client for every implemented cmux-tui protocol-v10
command and event. Protocol models and the canonical command surface are
generated from `spec/sdk-schema.json`. Socket transport, JSON, synchronization,
errors, stream lifecycle, and conveniences remain handwritten.

The first complete package release is `com.cmux:cmux-java-sdk:0.4.0`.

## Build and test

```bash
cd cmux-tui/bindings/java
scripts/test.sh
```

The build creates `build/cmux-java-sdk.jar`. Maven metadata is also included:

```bash
mvn -q package
```

## Commands

```java
try (CmuxClient client = CmuxClient.builder().build()) {
    IdentifyResult server = client.identify();
    UInt64 surface = UInt64.parse("18446744073709551615");

    client.send(
        SendRequest.builder()
            .surface(surface)
            .text("echo hello\r")
            .build()
    );
    String screen = client.readScreen(
        ReadScreenRequest.builder().surface(surface).build()
    ).text();
}
```

Every command has one generated camel-case method and immutable request/result
models. Optional fields use `Field<T>` so omission and explicit JSON null remain
distinct. `UInt64` accepts the full `0..18446744073709551615` range without
signed-long truncation.

`CmuxClient.builder()` connects to an explicit socket first, then
`CMUX_TUI_SOCKET`, legacy `CMUX_MUX_SOCKET`, and finally the server's
`XDG_RUNTIME_DIR` / `TMPDIR` / `/tmp` session path with the short-path fallback.
The default Unix profile enables control, frontend, and local-admin authority.
Provider commands require `enableProviderAuthority()` plus the command's
authority value.

## Streams

`subscribeEvents()`, `subscribeDeltas()`, `attachBytes()`, `attachRender()`,
and `attachBrowser()` return closeable synchronous streams. Each stream owns a
socket, preserves events received before its command acknowledgement, exposes
generated event types, and returns `UnknownEvent` for future wire event names.
Closing a stream unblocks a pending `next()` call.

```java
try (CmuxStream<DeltaStreamEvent> events = client.subscribeDeltas()) {
    DeltaStreamEvent event = events.next(Duration.ofSeconds(30));
}
```

## Render text and scrollback tails

`RenderText.plainText(RenderRun)`, `plainText(RenderRow)`, and
`plainText(List<RenderRow>)` discard style metadata and preserve run order.
Rows are joined with one newline and no trailing newline.

`client.readScrollbackTail(surface, count)` reads up to the last `count` retained
rows. It validates `0 <= count <= CmuxClient.MAX_SCROLLBACK_PAGE_ROWS` (65,535).
For a nonzero count, the helper sends a zero-count probe followed by one page
request. Eviction or resize reflow between those snapshots can shift the range.

## Owned workspaces

`createWorkspaceLease(request)` creates a workspace and returns an
`AutoCloseable` owner. A successful lease close sends `close-workspace` once;
a failed close remains retryable. Keep the client open until the lease closes.

```java
try (CmuxClient client = CmuxClient.builder().build();
     WorkspaceLease workspace = client.createWorkspaceLease(
         CreateWorkspaceRequest.builder().name("task").build()
     )) {
    System.out.println(workspace.workspace());
}
```

The default request limit is 4 MiB, the response/event limit is 16 MiB, the
JSON nesting limit is 128, and a stream may buffer at most 1,024 events before
its acknowledgement. Configure them with `maxRequestBytes`,
`maxResponseBytes`, `maxJsonDepth`, and `maxBufferedStreamEvents` on the client
builder.
