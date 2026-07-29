package com.cmux;

import java.io.IOException;
import java.math.BigInteger;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

public final class ResourceApiTest {
    private static final String HEX = "0123456789abcdef0123456789abcdef";

    private ResourceApiTest() {}

    public static void main(String[] args) {
        decimalAndIdentifiers();
        sensitiveValuesAreRedacted();
        exactCommandAndRouting();
        nullableMetadata();
        typedStream();
        streamCancellationPreservesRouteAndEnd();
        structuredErrorsAreNotRetried();
    }

    private static void decimalAndIdentifiers() {
        require(
            Decimal.parse("18446744073709551615").equals(Decimal.MAX_VALUE),
            "full uint64 decimal"
        );
        require(
            Decimal.of(new BigInteger("18446744073709551615")).toWire()
                .equals("18446744073709551615"),
            "decimal wire form"
        );
        expect(IllegalArgumentException.class, () -> Decimal.parse("01"));
        expect(
            IllegalArgumentException.class,
            () -> new Ids.TerminalId("term_ABC")
        );
        Ids.TerminalId terminal = new Ids.TerminalId("term_" + HEX);
        require(
            Selector.id(terminal).toWire().equals(terminal.value()),
            "typed ID selector"
        );
        require(
            Selector.<Ids.TerminalId>name("").toWire().equals("name:"),
            "empty exact-name selector"
        );
    }

    private static void sensitiveValuesAreRedacted() {
        Secret token = new Secret("renderer-secret");
        ProviderCredential credential =
            new ProviderCredential("password", new Secret("provider-secret"));
        RendererGrant grant = new RendererGrant(
            "wss://renderer.invalid",
            new Ids.TerminalId("term_" + HEX),
            token,
            List.of("read"),
            1_000
        );
        require(!token.toString().contains("renderer-secret"), "secret redaction");
        require(
            !credential.toString().contains("provider-secret"),
            "credential redaction"
        );
        require(
            !grant.toString().contains("renderer-secret"),
            "renderer grant redaction"
        );
        require(token.reveal().equals("renderer-secret"), "explicit reveal");
        ExternalMachineSpecifier specifier =
            new ExternalMachineSpecifier("provider://machine-secret");
        require(
            !specifier.toString().contains("machine-secret"),
            "machine specifier redaction"
        );
        require(
            specifier.reveal().equals("provider://machine-secret"),
            "explicit machine specifier reveal"
        );
    }

    private static void exactCommandAndRouting() {
        FakeTransport transport = new FakeTransport();
        try (Client client = client(transport)) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Workspace workspace = session.workspace(
                Selector.id(new Ids.WorkspaceId("ws_" + HEX))
            );
            MutationResult<CreatedPath> created = workspace.run(
                Options.Run.builder(
                    ExactCommand.of("printf", "%s", "hello world")
                ).build()
            );
            require(
                created.value().terminal().orElseThrow().value()
                    .equals("term_" + HEX),
                "typed created terminal path"
            );
            require(
                created.generation().equals("generation-1") &&
                    created.revision().equals(Decimal.MAX_VALUE) &&
                    !created.replayed(),
                "exact mutation envelope"
            );
            Map<String, Object> request = transport.lastSent();
            require(
                request.get("operation").equals("workspace.run"),
                "workspace run operation"
            );
            Map<String, Object> params = object(request.get("params"));
            require(params.get("machine").equals("current"), "machine route");
            require(params.get("session").equals("current"), "session route");
            require(params.get("workspace").equals("ws_" + HEX), "workspace route");
            require(
                params.get("argv").equals(
                    List.of("printf", "%s", "hello world")
                ),
                "exact argv wire field"
            );
            require(!params.containsKey("shell"), "exact command avoids shell");
            String key = String.valueOf(request.get("idempotency_key"));
            require(key.equals("idem-test"), "injected idempotency key");
        }
    }

    private static void nullableMetadata() {
        FakeTransport transport = new FakeTransport();
        try (Client client = client(transport)) {
            ConnectedClient connected = client.machine(Selector.current())
                .session(Selector.current())
                .connectedClient(
                    Selector.id(new Ids.ConnectedClientId("client_" + HEX))
                );
            connected.updateMetadata(
                Options.ClientMetadata.builder().clearName().kind("").build()
            );
            Map<String, Object> params = object(
                transport.lastSent().get("params")
            );
            require(params.containsKey("name"), "nullable name is present");
            require(params.get("name") == null, "nullable name clears with null");
            require(params.get("kind").equals(""), "empty kind is preserved");
        }
    }

    private static void typedStream() {
        FakeTransport transport = new FakeTransport();
        try (Client client = client(transport);
             ResourceStream<SessionEvent> stream = client
                 .machine(Selector.current())
                 .session(Selector.current())
                 .events(new Options.SessionEvents(
                     Options.Stream.defaults(),
                     Optional.empty()
                 ))) {
            StreamItem<SessionEvent> item = stream.next(Duration.ofSeconds(1));
            require(
                item.sequence().equals(Decimal.MAX_VALUE),
                "typed stream sequence"
            );
            require(
                item.value() instanceof SessionEvent.Unknown unknown &&
                    unknown.kind().equals("future-session-item") &&
                    unknown.raw().get("new_field").equals("preserved"),
                "unknown stream variant is preserved"
            );
            StreamEndError end = expect(
                StreamEndError.class,
                () -> stream.next(Duration.ofSeconds(1))
            );
            require(end.reason().equals("completed"), "typed stream end");
        }
    }

    private static void structuredErrorsAreNotRetried() {
        FakeTransport transport = new FakeTransport();
        transport.failBrowserNavigate = true;
        try (Client client = client(transport)) {
            Browser browser = client.machine(Selector.current())
                .session(Selector.current())
                .browser(Selector.id(new Ids.BrowserId("browser_" + HEX)));
            ResourceError error = expect(
                ResourceError.class,
                () -> browser.navigate(
                    new Options.Navigate(
                        Options.Mutation.defaults(),
                        "https://example.com"
                    )
                )
            );
            require(
                error.code().equals("mutation.indeterminate"),
                "structured code"
            );
            require(!error.retryable(), "structured retryability");
            require(
                error.details().get("recovery")
                    .equals("inspect_state_then_retry_with_new_key"),
                "indeterminate recovery is preserved"
            );
            require(
                transport.operationCount("browser.navigate") == 1,
                "mutation is not retried"
            );
        }
    }

    private static void streamCancellationPreservesRouteAndEnd() {
        FakeTransport transport = new FakeTransport();
        transport.cancelableStream = true;
        try (Client client = client(transport)) {
            Ids.SessionId sessionId = new Ids.SessionId("session_" + HEX);
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.id(sessionId))
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            stream.close();
            stream.close();
            Map<String, Object> request = transport.lastSent();
            require(
                request.get("operation").equals("stream.cancel"),
                "stream cancel operation"
            );
            Map<String, Object> params = object(request.get("params"));
            require(params.get("machine").equals("current"), "cancel machine route");
            require(
                params.get("session").equals(sessionId.value()),
                "cancel session route"
            );
            require(params.containsKey("stream"), "cancel stream selector");
            require(!params.containsKey("stream_id"), "cancel avoids open field");
            require(
                stream.end().orElseThrow().reason().equals("canceled"),
                "canceled server end is preserved"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "stream cancellation is one-shot"
            );
        }
    }

    private static Client client(FakeTransport transport) {
        return Client.builder()
            .transport(transport)
            .timeout(Duration.ofSeconds(1))
            .idempotencyKeySource(() -> "idem-test")
            .streamIdSource(() -> "stream_" + HEX)
            .build();
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> object(Object value) {
        return (Map<String, Object>) value;
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static <T extends Throwable> T expect(
        Class<T> type,
        ThrowingRunnable action
    ) {
        try {
            action.run();
        } catch (Throwable error) {
            if (type.isInstance(error)) {
                return type.cast(error);
            }
            throw new AssertionError(
                "expected " + type.getName() + ", got " + error,
                error
            );
        }
        throw new AssertionError("expected " + type.getName());
    }

    @FunctionalInterface
    private interface ThrowingRunnable {
        void run() throws Exception;
    }

    private static final class FakeTransport implements Transport {
        private final BlockingQueue<Map<String, Object>> inbound =
            new LinkedBlockingQueue<>();
        private final List<Map<String, Object>> sent = new ArrayList<>();
        private volatile boolean closed;
        private boolean failBrowserNavigate;
        private boolean cancelableStream;
        private String openStreamId;

        @Override
        public synchronized void send(Map<String, Object> message) {
            Map<String, Object> copy = new LinkedHashMap<>(message);
            sent.add(copy);
            String operation = String.valueOf(copy.get("operation"));
            String id = String.valueOf(copy.get("id"));
            Map<String, Object> params = object(copy.get("params"));
            if (cancelableStream && operation.equals("stream.cancel")) {
                inbound.add(Map.of(
                    "protocol", "cmux.protocol/1",
                    "type", "stream_end",
                    "stream_id", openStreamId,
                    "reason", "canceled"
                ));
                inbound.add(response(id, true, Map.of(), Map.of()));
                return;
            }
            if (failBrowserNavigate && operation.equals("browser.navigate")) {
                inbound.add(response(
                    id,
                    false,
                    Map.of(),
                    Map.of(
                        "code", "mutation.indeterminate",
                        "message", "mutation outcome is unknown",
                        "details", Map.of(
                            "idempotency_key", "idem-test",
                            "operation", "browser.navigate",
                            "recovery", "inspect_state_then_retry_with_new_key"
                        ),
                        "retryable", false
                    )
                ));
                return;
            }
            Map<String, Object> result = switch (operation) {
                case "workspace.run" -> workspaceRunResult();
                case "client.metadata.update" -> Map.of(
                    "client", clientSnapshot()
                );
                case "session.events", "stream.cancel" -> Map.of();
                default -> Map.of();
            };
            inbound.add(response(id, true, result, Map.of()));
            if (operation.equals("session.events")) {
                String streamId = String.valueOf(params.get("stream_id"));
                openStreamId = streamId;
                if (cancelableStream) {
                    return;
                }
                inbound.add(Map.of(
                    "protocol", "cmux.protocol/1",
                    "type", "stream_item",
                    "stream_id", streamId,
                    "sequence", "18446744073709551615",
                    "cursor", Map.of(
                        "generation", "generation-1",
                        "revision", "18446744073709551615"
                    ),
                    "item", Map.of(
                        "kind", "future-session-item",
                        "new_field", "preserved"
                    )
                ));
                inbound.add(Map.of(
                    "protocol", "cmux.protocol/1",
                    "type", "stream_end",
                    "stream_id", streamId,
                    "reason", "completed"
                ));
            }
        }

        @Override
        public Map<String, Object> receive() throws IOException {
            try {
                Map<String, Object> value = inbound.take();
                if (closed && value.isEmpty()) {
                    throw new IOException("closed");
                }
                return value;
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new IOException("interrupted", error);
            }
        }

        @Override
        public void close() {
            closed = true;
            inbound.offer(Map.of());
        }

        synchronized Map<String, Object> lastSent() {
            return sent.get(sent.size() - 1);
        }

        synchronized long operationCount(String operation) {
            return sent.stream()
                .filter(value -> operation.equals(value.get("operation")))
                .count();
        }

        private static Map<String, Object> workspaceRunResult() {
            return Map.of(
                "value", Map.of(
                    "kind", "terminal",
                    "workspace_id", "ws_" + HEX,
                    "screen_id", "screen_" + HEX,
                    "pane_id", "pane_" + HEX,
                    "tab_id", "tab_" + HEX,
                    "terminal_id", "term_" + HEX
                ),
                "generation", "generation-1",
                "revision", "18446744073709551615",
                "replayed", false
            );
        }

        private static Map<String, Object> clientSnapshot() {
            Map<String, Object> value = new LinkedHashMap<>();
            value.put("id", "client_" + HEX);
            value.put("session_id", "session_" + HEX);
            value.put("name", null);
            value.put("client_kind", "");
            value.put("transport", "unix");
            value.put("connected_seconds", "0");
            value.put("attached_terminal_ids", List.of());
            value.put("sizes", List.of());
            value.put("self", true);
            value.put("extra", Map.of());
            return value;
        }

        private static Map<String, Object> response(
            String id,
            boolean ok,
            Map<String, Object> result,
            Map<String, Object> error
        ) {
            Map<String, Object> value = new LinkedHashMap<>();
            value.put("protocol", "cmux.protocol/1");
            value.put("type", "response");
            value.put("id", id);
            value.put("ok", ok);
            if (ok) {
                value.put("result", result);
            } else {
                value.put("error", error);
            }
            return value;
        }
    }
}
