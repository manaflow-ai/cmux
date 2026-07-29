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
        creationCorrelationIsFirstClass();
        nullableMetadata();
        notificationTargetingIsOptionalAndTyped();
        strictTypedModels();
        layoutUndoUsesTypedConfirmation();
        creationResolutionAndWaitExitStaySeparate();
        typedStream();
        streamCancellationPreservesRouteAndEnd();
        structuredErrorsAreNotRetried();
        transportFailureReportsUncertainMutation();
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
        RendererGrant grant = new RendererGrant(
            "wss://renderer.invalid",
            new Ids.TerminalId("term_" + HEX),
            token,
            List.of("read"),
            1_000
        );
        require(!token.toString().contains("renderer-secret"), "secret redaction");
        require(
            !grant.toString().contains("renderer-secret"),
            "renderer grant redaction"
        );
        require(token.reveal().equals("renderer-secret"), "explicit reveal");
    }

    private static void exactCommandAndRouting() {
        FakeTransport transport = new FakeTransport();
        try (Client client = client(transport)) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Workspace workspace = session.workspace(
                Selector.id(new Ids.WorkspaceId("ws_" + HEX))
            );
            MutationResult<CreatedTerminalPath> created = workspace.run(
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

    private static void notificationTargetingIsOptionalAndTyped() {
        FakeTransport transport = new FakeTransport();
        try (Client client = client(transport)) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());

            session.createNotification(new Options.NotificationCreate(
                Options.Mutation.defaults(),
                "Session warning",
                "No terminal owns this warning",
                Optional.of("warning")
            ));
            Map<String, Object> sessionParams = object(
                transport.lastSent().get("params")
            );
            require(
                !sessionParams.containsKey("terminal_id"),
                "session-scoped notification omits terminal_id"
            );

            Ids.TerminalId terminalId =
                new Ids.TerminalId("term_" + HEX);
            MutationResult<Notification> targeted =
                session.createNotification(new Options.NotificationCreate(
                    Options.Mutation.defaults(),
                    "Task failed",
                    "The selected terminal exited",
                    Optional.of("error"),
                    Optional.of(terminalId)
                ));
            Map<String, Object> terminalParams = object(
                transport.lastSent().get("params")
            );
            require(
                terminalParams.get("terminal_id").equals(terminalId.value()),
                "terminal-targeted notification serializes terminal_id"
            );
            require(
                targeted.value().snapshot().terminalId()
                    .equals(Optional.of(terminalId)),
                "terminal-targeted notification decodes terminal_id"
            );
        }
    }

    private static void creationCorrelationIsFirstClass() {
        expect(
            IllegalArgumentException.class,
            () -> Options.WorkspaceCreate.builder()
                .correlationKey("")
                .build()
        );
        expect(
            IllegalArgumentException.class,
            () -> Options.Run.builder(ExactCommand.of("true"))
                .correlationKey("é".repeat(65))
                .build()
        );

        FakeTransport transport = new FakeTransport();
        try (Client client = client(transport)) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Workspace workspace = session.workspace(Selector.current());
            Screen screen = workspace.screen(Selector.current());
            Pane pane = screen.pane(Selector.current());

            session.createWorkspace(
                Options.WorkspaceCreate.builder()
                    .correlationKey("workspace-create")
                    .build()
            );
            requireLastCorrelation(
                transport,
                "workspace.create",
                "workspace-create"
            );

            workspace.run(
                Options.Run.builder(ExactCommand.of("true"))
                    .correlationKey("workspace-run")
                    .build()
            );
            requireLastCorrelation(
                transport,
                "workspace.run",
                "workspace-run"
            );

            workspace.createScreen(new Options.ScreenCreate(
                Options.Mutation.defaults(),
                Optional.empty(),
                Optional.of("screen-create")
            ));
            requireLastCorrelation(
                transport,
                "screen.create",
                "screen-create"
            );

            screen.createPane(new Options.PaneCreate(
                Options.Mutation.defaults(),
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                Optional.of("pane-create")
            ));
            requireLastCorrelation(
                transport,
                "pane.create",
                "pane-create"
            );

            pane.run(
                Options.Run.builder(ExactCommand.of("true"))
                    .correlationKey("pane-run")
                    .build()
            );
            requireLastCorrelation(transport, "pane.run", "pane-run");

            pane.split(new Options.PaneSplit(
                Options.Mutation.defaults(),
                Options.Direction.RIGHT,
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                Optional.of("pane-split")
            ));
            requireLastCorrelation(transport, "pane.split", "pane-split");

            pane.createTerminalTab(new Options.TabCreateTerminal(
                Options.Mutation.defaults(),
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                Optional.empty(),
                Optional.of("terminal-tab")
            ));
            requireLastCorrelation(
                transport,
                "tab.create_terminal",
                "terminal-tab"
            );

            pane.createBrowserTab(new Options.TabCreateBrowser(
                Options.Mutation.defaults(),
                Optional.empty(),
                "https://example.com",
                Optional.empty(),
                Optional.empty(),
                Optional.of("browser-tab")
            ));
            requireLastCorrelation(
                transport,
                "tab.create_browser",
                "browser-tab"
            );
        }
    }

    private static void strictTypedModels() {
        ResourceChange change = Client.decodeResourceChange(Map.of(
            "kind", "delete",
            "sequence", 7,
            "resource", "terminal",
            "id", "term_" + HEX
        ));
        require(
            change instanceof ResourceChange.Delete deleted &&
                deleted.sequence() == 7 &&
                deleted.id().value().equals("term_" + HEX),
            "known resource change is typed"
        );
        expect(
            ProtocolError.class,
            () -> Client.decodeResourceChange(Map.of(
                "kind", "delete",
                "sequence", 7,
                "resource", "terminal",
                "id", "term_" + HEX,
                "future", true
            ))
        );
        ResourceChange future = Client.decodeResourceChange(Map.of(
            "kind", "future-change",
            "future", Map.of("preserved", true)
        ));
        require(
            future instanceof ResourceChange.Unknown unknown &&
                object(unknown.raw().get("future")).get("preserved")
                    .equals(true),
            "unknown resource change preserves its raw object"
        );

        Render.Scroll scroll = Client.decodeRenderScroll(Map.of(
            "offset", "18446744073709551615",
            "at_bottom", true
        ));
        require(
            scroll.offset().equals(Decimal.MAX_VALUE) && scroll.atBottom(),
            "render result preserves uint64 and typed fields"
        );
        expect(
            ProtocolError.class,
            () -> Client.decodeRenderScroll(Map.of(
                "offset", "0",
                "at_bottom", true,
                "future", true
            ))
        );

        Map<String, Object> layoutFields = new LinkedHashMap<>();
        layoutFields.put("version", 1);
        layoutFields.put("screen_id", "screen_" + HEX);
        layoutFields.put("active_pane_id", "pane_" + HEX);
        layoutFields.put("zoomed_pane_id", null);
        layoutFields.put("root", Map.of(
            "kind", "leaf",
            "pane_id", "pane_" + HEX,
            "tab_ids", List.of("tab_" + HEX),
            "active_tab_id", "tab_" + HEX
        ));
        Layout.Document layout = Client.decodeLayoutDocument(layoutFields);
        require(
            layout.root() instanceof Layout.Leaf leaf &&
                leaf.activeTabId().orElseThrow().value()
                    .equals("tab_" + HEX),
            "layout result is recursively typed"
        );

        Snapshots.TerminalSnapshot terminal = Client.decodeTerminal(Map.of(
            "id", "term_" + HEX,
            "tab_id", "tab_" + HEX,
            "title", "done",
            "cols", 80,
            "rows", 24,
            "running", false,
            "lifecycle", "exited",
            "exit", Map.of(
                "outcome", Map.of("kind", "exit", "code", 0),
                "exited_at", "10",
                "revision", "11"
            )
        ));
        require(
            terminal.lifecycle() ==
                    Snapshots.TerminalLifecycle.EXITED &&
                terminal.exit().orElseThrow().outcome() instanceof
                    Results.TerminalExitCode,
            "terminal snapshot exposes typed lifecycle and exit"
        );
        expect(
            IllegalArgumentException.class,
            () -> Client.decodeTerminal(Map.of(
                "id", "term_" + HEX,
                "tab_id", "tab_" + HEX,
                "title", "bad",
                "cols", 80,
                "rows", 24,
                "running", true,
                "lifecycle", "launching"
            ))
        );
    }

    private static void creationResolutionAndWaitExitStaySeparate() {
        Results.CreationResolution created =
            Client.decodeCreationResolution(Map.of(
                "correlation_key", "create-key",
                "state", "created",
                "recovery", "none",
                "operation", "workspace.run",
                "idempotency_key", "idem-test",
                "created_path", Map.of(
                    "kind", "terminal",
                    "workspace_id", "ws_" + HEX,
                    "screen_id", "screen_" + HEX,
                    "pane_id", "pane_" + HEX,
                    "tab_id", "tab_" + HEX,
                    "terminal_id", "term_" + HEX
                ),
                "generation", "generation-1",
                "revision", "12"
            ));
        require(
            created.createdPath().orElseThrow()
                instanceof CreatedTerminalPath,
            "created resolution decodes its raw CreatedPath value"
        );

        FakeTransport transport = new FakeTransport();
        try (Client client = client(transport)) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Results.CreationResolution resolution = session.resolveCreation(
                new Options.CreationResolve(
                    Options.Read.defaults(),
                    "create-key"
                )
            );
            require(
                resolution.state() == Results.CreationState.PENDING &&
                    resolution.recovery() ==
                        Results.CreationRecovery.WAIT,
                "creation resolution reports durable creation state"
            );
            require(
                transport.lastSent().get("operation")
                    .equals("session.creation.resolve"),
                "creation resolution uses its own operation"
            );

            Results.TerminalWaitExitResult exit = session
                .terminal(Selector.id(
                    new Ids.TerminalId("term_" + HEX)
                ))
                .waitExit(Options.WaitExit.defaults());
            require(
                exit instanceof Results.TerminalWaitExitExited exited &&
                    exited.outcome() instanceof
                        Results.TerminalExitSignal signal &&
                    signal.signal() == 15 &&
                    !signal.coreDumped(),
                "terminal wait-exit decodes its closed outcome union"
            );
            require(
                transport.lastSent().get("operation")
                    .equals("terminal.wait_exit"),
                "terminal wait-exit remains separate from text matching"
            );
        }
    }

    private static void layoutUndoUsesTypedConfirmation() {
        expect(
            IllegalArgumentException.class,
            () -> new Options.LayoutUndo(
                Options.Mutation.defaults(),
                true,
                Optional.empty()
            )
        );
        expect(
            IllegalArgumentException.class,
            () -> Options.LayoutUndo.confirmed(
                Options.Mutation.defaults(),
                "x".repeat(129)
            )
        );

        FakeTransport transport = new FakeTransport();
        try (Client client = client(transport)) {
            ResourceError error = expect(
                ResourceError.class,
                () -> client.machine(Selector.current())
                    .session(Selector.current())
                    .workspace(Selector.current())
                    .screen(Selector.current())
                    .undoLayout(Options.LayoutUndo.confirmed(
                        Options.Mutation.defaults().expecting(Decimal.parse("8")),
                        "confirm-8"
                    ))
            );
            ConfirmationRequiredDetails details =
                error.confirmationRequiredDetails().orElseThrow();
            require(
                details.confirmationToken().equals("confirm-9") &&
                    details.revision().equals(Decimal.parse("9")) &&
                    details.closesPanes().equals(List.of(
                        new Ids.PaneId("pane_" + HEX)
                    )),
                "confirmation.required details are typed"
            );

            Map<String, Object> params = object(
                transport.lastSent().get("params")
            );
            require(
                params.get("confirm_close").equals(true),
                "confirmed undo sets confirm_close"
            );
            require(
                params.get("confirmation_token").equals("confirm-8"),
                "confirmed undo sends the exact token"
            );
            require(
                params.get("expected_revision").equals("8"),
                "confirmed undo sends the preview revision"
            );
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

    private static void transportFailureReportsUncertainMutation() {
        FakeTransport transport = new FakeTransport();
        transport.failMutationTransport = true;
        try (Client client = client(transport)) {
            Browser browser = client.machine(Selector.current())
                .session(Selector.current())
                .browser(Selector.id(new Ids.BrowserId("browser_" + HEX)));
            MutationOutcomeUncertain error = expect(
                MutationOutcomeUncertain.class,
                () -> browser.navigate(
                    new Options.Navigate(
                        Options.Mutation.keyed("exact-key"),
                        "https://example.com"
                    )
                )
            );
            require(
                error.operation().equals("browser.navigate"),
                "uncertain mutation retains its exact operation"
            );
            require(
                error.idempotencyKey().equals("exact-key"),
                "uncertain mutation retains its exact idempotency key"
            );
            require(
                transport.operationCount("browser.navigate") == 1,
                "transport-failed mutation is not retried"
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
            require(
                stream.poll(Duration.ofMillis(10)).isEmpty(),
                "bounded stream poll reports a local timeout"
            );
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

    private static void requireLastCorrelation(
        FakeTransport transport,
        String operation,
        String correlationKey
    ) {
        Map<String, Object> request = transport.lastSent();
        require(
            request.get("operation").equals(operation),
            operation + " operation"
        );
        require(
            object(request.get("params"))
                .get("correlation_key")
                .equals(correlationKey),
            operation + " correlation_key"
        );
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
        private boolean failMutationTransport;
        private boolean cancelableStream;
        private String openStreamId;

        @Override
        public synchronized void send(Map<String, Object> message)
                throws IOException {
            Map<String, Object> copy = new LinkedHashMap<>(message);
            sent.add(copy);
            String operation = String.valueOf(copy.get("operation"));
            String id = String.valueOf(copy.get("id"));
            Map<String, Object> params = object(copy.get("params"));
            if (failMutationTransport &&
                    operation.equals("browser.navigate")) {
                throw new IOException("response path failed");
            }
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
            if (operation.equals("screen.layout.undo")) {
                inbound.add(response(
                    id,
                    false,
                    Map.of(),
                    Map.of(
                        "code", "confirmation.required",
                        "message", "undo closes panes",
                        "details", Map.of(
                            "confirmation_token", "confirm-9",
                            "revision", "9",
                            "closes_panes", List.of("pane_" + HEX)
                        ),
                        "retryable", false
                    )
                ));
                return;
            }
            Map<String, Object> result = switch (operation) {
                case "workspace.create",
                     "workspace.run",
                     "screen.create",
                     "pane.create",
                     "pane.run",
                     "pane.split",
                     "tab.create_terminal" -> workspaceRunResult();
                case "tab.create_browser" -> browserCreateResult();
                case "client.metadata.update" -> clientSnapshot();
                case "session.creation.resolve" -> Map.of(
                    "correlation_key", "create-key",
                    "state", "pending",
                    "recovery", "wait"
                );
                case "terminal.wait_exit" -> Map.of(
                    "state", "exited",
                    "terminal_id", "term_" + HEX,
                    "lifecycle", "exited",
                    "outcome", Map.of(
                        "kind", "signal",
                        "signal", 15,
                        "core_dumped", false
                    ),
                    "exited_at", "10",
                    "revision", "11"
                );
                case "notification.create" ->
                    notificationCreateResult(params);
                case "session.events" -> Map.of(
                    "stream_id",
                    String.valueOf(params.get("stream_id"))
                );
                case "stream.cancel" -> Map.of();
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

        private static Map<String, Object> browserCreateResult() {
            return Map.of(
                "value", Map.of(
                    "kind", "browser",
                    "workspace_id", "ws_" + HEX,
                    "screen_id", "screen_" + HEX,
                    "pane_id", "pane_" + HEX,
                    "tab_id", "tab_" + HEX,
                    "browser_id", "browser_" + HEX
                ),
                "generation", "generation-1",
                "revision", "18446744073709551615",
                "replayed", false
            );
        }

        private static Map<String, Object> notificationCreateResult(
            Map<String, Object> params
        ) {
            Map<String, Object> notification = new LinkedHashMap<>();
            notification.put("id", "notification_" + HEX);
            notification.put("session_id", "session_" + HEX);
            notification.put("title", params.get("title"));
            notification.put("body", params.get("body"));
            notification.put("level", params.getOrDefault("level", "info"));
            if (params.containsKey("terminal_id")) {
                notification.put("terminal_id", params.get("terminal_id"));
            }
            notification.put("created_at_ms", "100");
            notification.put("unread", true);
            return Map.of(
                "value", notification,
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
