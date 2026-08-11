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
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

public final class ResourceApiTest {
    private static final String HEX = "0123456789abcdef0123456789abcdef";

    private ResourceApiTest() {}

    public static void main(String[] args) {
        decimalAndIdentifiers();
        journalRegexDefaultsAreErgonomic();
        sensitiveValuesAreRedacted();
        defaultIdempotencyKeysUseFixedWidthLowercaseHex();
        idempotencyKeysMatchDurableIdentifierContract();
        exactCommandAndRouting();
        creationCorrelationIsFirstClass();
        nullableMetadata();
        notificationTargetingIsOptionalAndTyped();
        strictTypedModels();
        layoutUndoUsesTypedConfirmation();
        creationResolutionAndWaitExitStaySeparate();
        terminalWaitTimeoutCancelsAndReusesConnection();
        terminalWaitAbortGatesConcurrentReuse();
        terminalWaitFalseRaceDrainsTargetResponse();
        terminalWaitResponseFirstFalseRaceDrainsCancelResponse();
        terminalWaitCleanupFailureClosesButPreservesAbort();
        terminalWaitCleanupDeadlineClosesButPreservesAbort();
        terminalWaitPredispatchInterruptSendsNothing();
        terminalWaitUncertainSendClosesWithoutCancel();
        typedStream();
        malformedStreamItemEnvelopeClosesConnection();
        idleStreamOutlivesRequestTimeout();
        failedStreamOpenIsCanceledAndQuotaRecovers();
        interruptedStreamOpenIsCanceledAndQuotaRecovers();
        ambiguousStreamOpenSendFailureClosesWithoutCancel();
        ordinaryBlockedSendHonorsRequestDeadline();
        predispatchInterruptionDoesNotScheduleCleanup();
        partialSiblingSendClosesWithoutAppendingCancel();
        readerFailureDoesNotAppendCancelAfterPartialSiblingSend();
        rejectedStreamOpenDoesNotCancelOrClose();
        streamOpenTransportFailureCancelsBeforeDisconnect();
        failedOpenCleanupBlocksConnectionReuseUntilConfirmed();
        failedStreamOpenCleanupDeadlineDoesNotPoisonLaterRequests();
        failedStreamOpenCleanupResponseTimeoutClosesConnection();
        failedStreamOpenCleanupWriteLockTimeoutClosesConnection();
        simultaneousBlockedCleanupsHaveIndependentDeadlines();
        cleanupAdmissionIsBoundedAndFailClosesOnSaturation();
        transportFailureWaitsForInFlightDispatchMarker();
        malformedCorrelatedResponseCompletesOpenPromptly();
        validAckBeforeTransportFailureDoesNotReturnDeadStream();
        streamCancellationPreservesRouteAndEnd();
        explicitCancelWaitsForEndAfterResponse();
        explicitCancelRejectsMalformedOrMissingEnd();
        explicitCancelRejectsMalformedResponseEnvelope();
        explicitCancelRejectsMalformedKnownQueuedItem();
        explicitCancelRetainsDecoderAfterEndUntilResponse();
        explicitCancelRejectsValidItemAfterEnd();
        concurrentExplicitCancelCallersShareFailure();
        explicitCancelBlockedSendHonorsTotalDeadline();
        explicitCancelTimeoutClosesConnection();
        overflowAndExplicitCloseShareOneCleanup();
        overflowInvalidCancelResultClosesWithoutDuplicate();
        overflowBlockedCancelHonorsTotalDeadline();
        structuredErrorsAreNotRetried();
        transportFailureReportsUncertainMutation();
    }

    private static void journalRegexDefaultsAreErgonomic() {
        Options.JournalRegexFilter filter = new Options.JournalRegexFilter("agent\\.");
        require(
            filter.field() == Options.JournalRegexField.RECORD,
            "journal regex defaults to the complete record"
        );
        require(filter.caseSensitive(), "journal regex defaults to case-sensitive matching");
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

    private static void defaultIdempotencyKeysUseFixedWidthLowercaseHex() {
        FakeTransport transport = new FakeTransport();
        try (Client client = Client.builder()
                .transport(transport)
                .timeout(Duration.ofSeconds(1))
                .build()) {
            client.machine(Selector.current())
                .session(Selector.current())
                .workspace(Selector.current())
                .run(Options.Run.builder(ExactCommand.of("true")).build());
            String key = String.valueOf(
                transport.lastSent().get("idempotency_key")
            );
            require(
                key.matches("\\Aidem_[0-9a-f]{32}\\z"),
                "default idempotency key is fixed-width lowercase hex"
            );
        }
    }

    private static void idempotencyKeysMatchDurableIdentifierContract() {
        for (String invalid : List.of(
                "",
                " \u00a0\u3000",
                "key\ncontrol",
                "key\u0085control",
                "é".repeat(65),
                "key\ud800")) {
            expect(
                IllegalArgumentException.class,
                () -> Options.Mutation.keyed(invalid)
            );
        }
        for (String valid : List.of(" key ", "\ufeff", "é".repeat(64))) {
            require(
                Options.Mutation.keyed(valid).idempotencyKey().orElseThrow()
                    .equals(valid),
                "valid idempotency key is preserved"
            );
        }

        FakeTransport transport = new FakeTransport();
        try (Client client = Client.builder()
                .transport(transport)
                .timeout(Duration.ofSeconds(1))
                .idempotencyKeySource(() -> " \u00a0\u3000")
                .build()) {
            expect(
                IllegalArgumentException.class,
                () -> client.machine(Selector.current())
                    .session(Selector.current())
                    .workspace(Selector.current())
                    .run(Options.Run.builder(ExactCommand.of("true")).build())
            );
            require(transport.sent.isEmpty(), "invalid generated key is not sent");
        }
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
                    .mutation(Options.Mutation.defaults().expecting(Decimal.parse("7")))
                    .correlationKey("workspace-create")
                    .build()
            );
            requireLastCorrelation(
                transport,
                "workspace.create",
                "workspace-create"
            );
            require(
                object(transport.lastSent().get("params"))
                    .get("expected_revision")
                    .equals("7"),
                "workspace.create expected_revision"
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
                Optional.of(0.5),
                Optional.of("pane-split")
            ));
            requireLastCorrelation(transport, "pane.split", "pane-split");
            require(
                object(transport.lastSent().get("params"))
                    .get("viewport_width")
                    .equals(0.5),
                "pane.split viewport_width"
            );

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
            "tab_ids", List.of("tab_" + HEX),
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
        Snapshots.TerminalSnapshot legacyTerminal = Client.decodeTerminal(Map.of(
            "id", "term_" + HEX,
            "tab_id", "tab_" + HEX,
            "title", "legacy",
            "cols", 80,
            "rows", 24,
            "running", true,
            "lifecycle", "running"
        ));
        require(
            legacyTerminal.tabIds().equals(List.of(new Ids.TabId("tab_" + HEX))),
            "protocol-one terminal tab_id expands to tabIds"
        );
        Map<String, Object> legacyDetachedFields = new LinkedHashMap<>();
        legacyDetachedFields.put("id", "term_" + HEX);
        legacyDetachedFields.put("tab_id", null);
        legacyDetachedFields.put("title", "legacy detached");
        legacyDetachedFields.put("cols", 80);
        legacyDetachedFields.put("rows", 24);
        legacyDetachedFields.put("running", true);
        legacyDetachedFields.put("lifecycle", "running");
        Snapshots.TerminalSnapshot legacyDetached =
            Client.decodeTerminal(legacyDetachedFields);
        require(
            legacyDetached.tabIds().isEmpty(),
            "protocol-one detached terminal expands to empty tabIds"
        );
        expect(
            ProtocolError.class,
            () -> Client.decodeTerminal(Map.of(
                "id", "term_" + HEX,
                "title", "missing views",
                "cols", 80,
                "rows", 24,
                "running", true,
                "lifecycle", "running"
            ))
        );
        Map<String, Object> missingDetachedViews = new LinkedHashMap<>();
        missingDetachedViews.put("id", "term_" + HEX);
        missingDetachedViews.put("tab_id", null);
        missingDetachedViews.put("title", "missing detached views");
        missingDetachedViews.put("cols", 80);
        missingDetachedViews.put("rows", 24);
        missingDetachedViews.put("running", true);
        missingDetachedViews.put("lifecycle", "running");
        require(
            Client.decodeTerminal(missingDetachedViews).tabIds().isEmpty(),
            "legacy detached terminal synthesizes empty tab_ids"
        );
        require(
            Client.decodeTerminal(Map.of(
                "id", "term_" + HEX,
                "tab_id", "tab_" + HEX,
                "title", "legacy attached",
                "cols", 80,
                "rows", 24,
                "running", true,
                "lifecycle", "running"
            )).tabIds().equals(List.of(new Ids.TabId("tab_" + HEX))),
            "legacy attached terminal synthesizes tab_ids"
        );
        require(
            Client.decodeTerminal(Map.of(
                "id", "term_" + HEX,
                "tab_id", "tab_" + HEX,
                "tab_ids", List.of("tab_" + HEX),
                "title", "dual placement",
                "cols", 80,
                "rows", 24,
                "running", true,
                "lifecycle", "running"
            )).tabIds().size() == 1,
            "consistent dual terminal placement is accepted"
        );
        expect(
            ProtocolError.class,
            () -> Client.decodeTerminal(Map.of(
                "id", "term_" + HEX,
                "tab_id", "tab_" + HEX,
                "tab_ids", List.of(),
                "title", "inconsistent",
                "cols", 80,
                "rows", 24,
                "running", true,
                "lifecycle", "running"
            ))
        );
        expect(
            IllegalArgumentException.class,
            () -> Client.decodeTerminal(Map.of(
                "id", "term_" + HEX,
                "tab_ids", List.of("tab_" + HEX),
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

    private static void terminalWaitTimeoutCancelsAndReusesConnection() {
        WaitCancelTransport transport = new WaitCancelTransport();
        try (Client client = waitClient(transport, Duration.ofMillis(30))) {
            AtomicReference<RuntimeException> failure = new AtomicReference<>();
            Thread waiter = new Thread(() -> {
                try {
                    waitTerminal(client).waitFor(waitOptions());
                } catch (RuntimeException error) {
                    failure.set(error);
                }
            }, "terminal-wait-timeout");
            waiter.start();
            require(transport.awaitWait(), "timed wait was dispatched");
            require(
                transport.awaitRequestCancel(),
                "timed wait dispatched request.cancel"
            );
            transport.respondCancel(Map.of("canceled", true));
            join(waiter, Duration.ofSeconds(1), "timed terminal wait cleanup");
            require(
                failure.get() instanceof TransportError &&
                    failure.get().getMessage().contains("timed out"),
                "wait preserves its original local timeout"
            );
            client.machine(Selector.current())
                .session(Selector.current())
                .ping(Options.Read.defaults());
            require(
                transport.operationCount("session.ping") == 1,
                "connection is reusable after confirmed cancellation"
            );
        }
    }

    private static void terminalWaitAbortGatesConcurrentReuse() {
        WaitCancelTransport transport = new WaitCancelTransport();
        try (Client client = waitClient(transport, Duration.ofSeconds(2))) {
            AtomicReference<RuntimeException> waitFailure =
                new AtomicReference<>();
            AtomicReference<Boolean> interruptRestored =
                new AtomicReference<>(false);
            Thread waiter = new Thread(() -> {
                try {
                    waitTerminal(client).waitFor(waitOptions());
                } catch (RuntimeException error) {
                    waitFailure.set(error);
                    interruptRestored.set(Thread.currentThread().isInterrupted());
                }
            }, "terminal-wait-abort");
            waiter.start();
            require(transport.awaitWait(), "aborted wait was dispatched");
            waiter.interrupt();
            require(
                transport.awaitRequestCancel(),
                "aborted wait dispatched request.cancel"
            );

            int followerCount = 4;
            BlockingQueue<RuntimeException> followerFailures =
                new LinkedBlockingQueue<>();
            List<Thread> followers = new ArrayList<>();
            for (int index = 0; index < followerCount; index++) {
                Thread follower = new Thread(() -> {
                    try {
                        client.machine(Selector.current())
                            .session(Selector.current())
                            .ping(Options.Read.defaults());
                    } catch (RuntimeException error) {
                        followerFailures.add(error);
                    }
                }, "request-cleanup-follower-" + index);
                followers.add(follower);
                follower.start();
            }
            sleep(Duration.ofMillis(40));
            require(
                transport.operationCount("session.ping") == 0,
                "concurrent reuse stays gated before cancel confirmation"
            );

            transport.respondCancel(Map.of("canceled", true));
            join(waiter, Duration.ofSeconds(1), "aborted terminal wait cleanup");
            for (Thread follower : followers) {
                join(
                    follower,
                    Duration.ofSeconds(1),
                    "request cleanup follower"
                );
            }
            require(
                followerFailures.isEmpty(),
                "all gated followers share successful cleanup"
            );
            require(
                transport.operationCount("request.cancel") == 1,
                "one cleanup owner sends one request.cancel"
            );
            require(
                waitFailure.get() instanceof TransportError &&
                    waitFailure.get().getMessage().contains("interrupted"),
                "wait preserves its original local abort"
            );
            require(
                interruptRestored.get(),
                "wait restores the caller interrupt after cleanup"
            );
        }
    }

    private static void terminalWaitFalseRaceDrainsTargetResponse() {
        WaitCancelTransport transport = new WaitCancelTransport();
        try (Client client = waitClient(transport, Duration.ofSeconds(2))) {
            AtomicReference<RuntimeException> failure = new AtomicReference<>();
            AtomicReference<Boolean> interruptRestored =
                new AtomicReference<>(false);
            Thread waiter = new Thread(() -> {
                try {
                    waitTerminal(client).waitExit(Options.WaitExit.defaults());
                } catch (RuntimeException error) {
                    failure.set(error);
                    interruptRestored.set(Thread.currentThread().isInterrupted());
                }
            }, "terminal-wait-false-race");
            waiter.start();
            require(transport.awaitWait(), "wait-exit was dispatched");
            waiter.interrupt();
            require(
                transport.awaitRequestCancel(),
                "wait-exit abort dispatched request.cancel"
            );
            transport.respondCancel(Map.of("canceled", false));
            sleep(Duration.ofMillis(40));
            require(
                waiter.isAlive(),
                "canceled=false waits for the original target response"
            );
            transport.respondTarget(Map.of(
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
            ));
            join(waiter, Duration.ofSeconds(1), "false-race target drain");
            require(
                failure.get() instanceof TransportError &&
                    failure.get().getMessage().contains("interrupted"),
                "false-race drain preserves the original abort"
            );
            require(
                interruptRestored.get(),
                "false-race drain restores the interrupt"
            );
            client.machine(Selector.current())
                .session(Selector.current())
                .ping(Options.Read.defaults());
        }
    }

    private static void terminalWaitResponseFirstFalseRaceDrainsCancelResponse() {
        WaitCancelTransport transport = new WaitCancelTransport();
        try (Client client = waitClient(transport, Duration.ofSeconds(2))) {
            AtomicReference<RuntimeException> failure = new AtomicReference<>();
            AtomicReference<Boolean> interruptRestored =
                new AtomicReference<>(false);
            Thread waiter = new Thread(() -> {
                try {
                    waitTerminal(client).waitFor(waitOptions());
                } catch (RuntimeException error) {
                    failure.set(error);
                    interruptRestored.set(Thread.currentThread().isInterrupted());
                }
            }, "terminal-wait-response-first-race");
            waiter.start();
            require(transport.awaitWait(), "response-first wait was dispatched");
            waiter.interrupt();
            require(
                transport.awaitRequestCancel(),
                "response-first abort dispatched request.cancel"
            );
            transport.respondTarget(Map.of(
                "matched", true,
                "text", "raced"
            ));
            sleep(Duration.ofMillis(40));
            require(
                waiter.isAlive(),
                "response-first race waits for request.cancel response"
            );
            transport.respondCancel(Map.of("canceled", false));
            join(waiter, Duration.ofSeconds(1), "response-first race drain");
            require(
                failure.get() instanceof TransportError &&
                    failure.get().getMessage().contains("interrupted"),
                "response-first race preserves the original abort"
            );
            require(
                interruptRestored.get(),
                "response-first race restores the interrupt"
            );
            client.machine(Selector.current())
                .session(Selector.current())
                .ping(Options.Read.defaults());
        }
    }

    private static void terminalWaitCleanupFailureClosesButPreservesAbort() {
        for (boolean malformedTarget : List.of(false, true)) {
            WaitCancelTransport transport = new WaitCancelTransport();
            try (Client client = waitClient(transport, Duration.ofSeconds(2))) {
                AtomicReference<RuntimeException> failure =
                    new AtomicReference<>();
                Thread waiter = new Thread(() -> {
                    try {
                        waitTerminal(client).waitFor(
                            waitOptions()
                        );
                    } catch (RuntimeException error) {
                        failure.set(error);
                    }
                }, malformedTarget
                    ? "malformed-wait-target"
                    : "malformed-cancel-confirmation");
                waiter.start();
                require(transport.awaitWait(), "cleanup-failure wait dispatched");
                waiter.interrupt();
                require(
                    transport.awaitRequestCancel(),
                    "cleanup-failure request.cancel dispatched"
                );
                if (malformedTarget) {
                    transport.respondCancel(Map.of("canceled", false));
                    transport.respondTarget(Map.of("matched", true));
                } else {
                    transport.respondCancel(Map.of(
                        "canceled", true,
                        "extra", true
                    ));
                }
                join(
                    waiter,
                    Duration.ofSeconds(1),
                    "failed request cancellation cleanup"
                );
                require(
                    failure.get() instanceof TransportError &&
                        failure.get().getMessage().contains("interrupted"),
                    "cleanup failure preserves the original abort"
                );
                require(client.isClosed(), "cleanup failure closes transport");
                long started = System.nanoTime();
                expect(
                    RuntimeException.class,
                    () -> client.machine(Selector.current())
                        .session(Selector.current())
                        .ping(Options.Read.defaults())
                );
                require(
                    Duration.ofNanos(System.nanoTime() - started)
                        .compareTo(Duration.ofMillis(100)) < 0,
                    "reuse after cleanup failure fails promptly"
                );
            }
        }
    }

    private static void terminalWaitCleanupDeadlineClosesButPreservesAbort() {
        WaitCancelTransport transport = new WaitCancelTransport();
        try (Client client = waitClient(transport, Duration.ofSeconds(2))) {
            AtomicReference<RuntimeException> failure = new AtomicReference<>();
            Thread waiter = new Thread(() -> {
                try {
                    waitTerminal(client).waitFor(waitOptions());
                } catch (RuntimeException error) {
                    failure.set(error);
                }
            }, "terminal-wait-cleanup-deadline");
            waiter.start();
            require(transport.awaitWait(), "deadline wait was dispatched");
            waiter.interrupt();
            require(
                transport.awaitRequestCancel(),
                "deadline abort dispatched request.cancel"
            );
            long started = System.nanoTime();
            join(waiter, Duration.ofSeconds(2), "request cleanup deadline");
            Duration elapsed = Duration.ofNanos(System.nanoTime() - started);
            require(
                elapsed.compareTo(Duration.ofMillis(1500)) < 0,
                "request cleanup exceeded its deadline: " + elapsed
            );
            require(
                failure.get() instanceof TransportError &&
                    failure.get().getMessage().contains("interrupted"),
                "cleanup deadline preserves the original abort"
            );
            require(client.isClosed(), "cleanup deadline closes transport");
            require(
                transport.operationCount("request.cancel") == 1,
                "cleanup deadline sends one request.cancel"
            );
        }
    }

    private static void terminalWaitPredispatchInterruptSendsNothing() {
        WaitCancelTransport transport = new WaitCancelTransport();
        try (Client client = waitClient(transport, Duration.ofSeconds(2))) {
            AtomicReference<RuntimeException> failure = new AtomicReference<>();
            AtomicReference<Boolean> interruptRestored =
                new AtomicReference<>(false);
            Thread waiter = new Thread(() -> {
                Thread.currentThread().interrupt();
                try {
                    waitTerminal(client).waitFor(waitOptions());
                } catch (RuntimeException error) {
                    failure.set(error);
                    interruptRestored.set(Thread.currentThread().isInterrupted());
                }
            }, "predispatch-interrupted-wait");
            waiter.start();
            join(waiter, Duration.ofSeconds(1), "predispatch interrupted wait");
            require(
                failure.get() instanceof TransportError,
                "predispatch interrupt is reported"
            );
            require(
                interruptRestored.get(),
                "predispatch interrupt remains set"
            );
            require(
                transport.operationCount("terminal.wait") == 0 &&
                    transport.operationCount("request.cancel") == 0,
                "predispatch interrupt sends no wait or cleanup"
            );
            client.machine(Selector.current())
                .session(Selector.current())
                .ping(Options.Read.defaults());
        }
    }

    private static void terminalWaitUncertainSendClosesWithoutCancel() {
        WaitCancelTransport transport = new WaitCancelTransport();
        transport.failWaitSend = true;
        try (Client client = waitClient(transport, Duration.ofSeconds(2))) {
            TransportError failure = expect(
                TransportError.class,
                () -> waitTerminal(client).waitFor(
                    waitOptions()
                )
            );
            require(
                failure.getMessage().contains("cannot send terminal.wait") &&
                    failure.getCause() != null &&
                    failure.getCause().getMessage().contains("wait send failed"),
                "uncertain wait send reports the transport failure"
            );
            require(client.isClosed(), "uncertain wait send fail-closes");
            require(
                transport.operationCount("terminal.wait") == 1 &&
                    transport.operationCount("request.cancel") == 0,
                "uncertain send never appends request.cancel"
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

    private static void malformedStreamItemEnvelopeClosesConnection() {
        FakeTransport transport = new FakeTransport();
        transport.delayStreamEvent = true;
        transport.invalidStreamItemExtra = true;
        try (Client client = client(transport);
             ResourceStream<SessionEvent> stream = client
                 .machine(Selector.current())
                 .session(Selector.current())
                 .events(new Options.SessionEvents(
                     Options.Stream.defaults(),
                     Optional.empty()
                 ))) {
            transport.releaseDelayedStreamEvent();
            expect(
                ProtocolError.class,
                () -> stream.next(Duration.ofSeconds(1))
            );
            require(
                transport.awaitClosed(),
                "malformed stream_item closes the connection"
            );
        }
    }

    private static void idleStreamOutlivesRequestTimeout() {
        FakeTransport transport = new FakeTransport();
        transport.delayStreamEvent = true;
        Duration requestTimeout = Duration.ofMillis(20);
        try (Client client = client(transport, requestTimeout);
             ResourceStream<SessionEvent> stream = client
                 .machine(Selector.current())
                 .session(Selector.current())
                 .events(new Options.SessionEvents(
                     Options.Stream.defaults(),
                     Optional.empty()
                 ))) {
            sleep(Duration.ofMillis(60));
            require(
                stream.poll(Duration.ofMillis(10)).isEmpty(),
                "an acknowledged idle stream remains open after the request timeout"
            );

            transport.releaseDelayedStreamEvent();
            StreamItem<SessionEvent> item = stream.next(
                Duration.ofSeconds(1)
            );
            require(
                item.value() instanceof SessionEvent.Unknown unknown &&
                    unknown.raw().get("new_field").equals("delayed"),
                "the idle stream receives its delayed event"
            );
            StreamEndError end = expect(
                StreamEndError.class,
                () -> stream.next(Duration.ofSeconds(1))
            );
            require(
                end.reason().equals("completed"),
                "the delayed stream retains its ordinary terminal event"
            );
        }
    }

    private static void failedStreamOpenIsCanceledAndQuotaRecovers() {
        for (StreamOpenFailure failure : List.of(
                StreamOpenFailure.TIMEOUT,
                StreamOpenFailure.MALFORMED_ACK,
                StreamOpenFailure.MISMATCHED_ACK)) {
            FakeTransport transport = new FakeTransport();
            transport.streamOpenFailure = failure;
            try (Client client = client(transport, Duration.ofMillis(25))) {
                Session session = client.machine(Selector.current())
                    .session(Selector.current());
                RuntimeException error = expect(
                    RuntimeException.class,
                    () -> session.events(new Options.SessionEvents(
                        Options.Stream.defaults(),
                        Optional.empty()
                    ))
                );
                if (failure == StreamOpenFailure.TIMEOUT) {
                    require(
                        error instanceof TransportError &&
                            error.getMessage().contains("timed out"),
                        "stream-open timeout remains the reported error"
                    );
                } else {
                    require(
                        error instanceof ProtocolError,
                        "invalid stream-open acknowledgment remains the reported error: " +
                            failure + " produced " + error
                    );
                }
                require(
                    transport.awaitFailedOpenCleanup(),
                    "failed stream open sends bounded cleanup for " + failure
                );
                require(
                    transport.operationCount("stream.cancel") == 1,
                    "failed stream open sends one cleanup for " + failure
                );

                transport.streamOpenFailure = StreamOpenFailure.NONE;
                transport.cancelableStream = true;
                try (ResourceStream<SessionEvent> recovered =
                        session.events(new Options.SessionEvents(
                            Options.Stream.defaults(),
                            Optional.empty()
                        ))) {
                    require(recovered.id() != null, "stream quota recovers");
                }
            }
        }
    }

    private static void interruptedStreamOpenIsCanceledAndQuotaRecovers() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure = StreamOpenFailure.TIMEOUT;
        try (Client client = client(transport, Duration.ofSeconds(5))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            AtomicReference<Throwable> failure = new AtomicReference<>();
            Thread opener = new Thread(() -> {
                try {
                    session.events(new Options.SessionEvents(
                        Options.Stream.defaults(),
                        Optional.empty()
                    ));
                } catch (Throwable error) {
                    failure.set(error);
                }
            }, "cmux-interrupted-stream-open-test");
            opener.start();
            require(
                transport.awaitFailedOpenDispatch(),
                "interrupted stream open reaches the transport"
            );
            opener.interrupt();
            try {
                opener.join(TimeUnit.SECONDS.toMillis(1));
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError("test interrupted", error);
            }
            require(!opener.isAlive(), "interrupted stream open returns");
            require(
                failure.get() instanceof TransportError &&
                    failure.get().getMessage().contains("interrupted"),
                "interruption remains the reported stream-open error"
            );
            require(
                transport.awaitFailedOpenCleanup(),
                "interrupted stream open sends bounded cleanup"
            );

            transport.streamOpenFailure = StreamOpenFailure.NONE;
            transport.cancelableStream = true;
            try (ResourceStream<SessionEvent> recovered =
                    session.events(new Options.SessionEvents(
                        Options.Stream.defaults(),
                        Optional.empty()
                    ))) {
                require(recovered.id() != null, "stream quota recovers");
            }
        }
    }

    private static void ambiguousStreamOpenSendFailureClosesWithoutCancel() {
        FakeTransport transport = new FakeTransport();
        transport.failStreamOpenSend = true;
        try (Client client = client(transport)) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            TransportError failure = expect(
                TransportError.class,
                () -> session.events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ))
            );
            require(
                failure.getMessage().contains("cannot send session.events"),
                "ambiguous send failure remains the reported error"
            );
            sleep(Duration.ofMillis(25));
            require(
                transport.operationCount("stream.cancel") == 0,
                "an unconfirmed open does not guess at stream cancellation"
            );
            require(
                transport.awaitClosed(),
                "an ambiguous open-send failure closes the transport"
            );
            require(
                !transport.serverStreamActive,
                "disconnect releases ambiguous server stream state"
            );
            expect(
                TransportError.class,
                () -> session.ping(Options.Read.defaults())
            );
        }
    }

    private static void ordinaryBlockedSendHonorsRequestDeadline() {
        FakeTransport transport = new FakeTransport();
        transport.blockPingSend = true;
        try (Client client = client(transport, Duration.ofMillis(50))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            long started = System.nanoTime();
            expect(
                TransportError.class,
                () -> session.ping(Options.Read.defaults())
            );
            require(
                Duration.ofNanos(System.nanoTime() - started)
                    .compareTo(Duration.ofSeconds(1)) < 0,
                "request deadline includes blocked dispatch"
            );
            require(
                transport.awaitClosed(),
                "blocked request dispatch closes the transport at deadline"
            );
        }
    }

    private static void rejectedStreamOpenDoesNotCancelOrClose() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure = StreamOpenFailure.REJECTED;
        try (Client client = client(transport)) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            ResourceError rejected = expect(
                ResourceError.class,
                () -> session.events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ))
            );
            require(
                rejected.code().equals("session.not_found"),
                "structured stream rejection is preserved"
            );
            require(
                transport.operationCount("stream.cancel") == 0,
                "structured rejection does not cancel a nonexistent route"
            );
            require(
                session.ping(Options.Read.defaults()).alive(),
                "connection remains reusable after structured rejection"
            );
            require(!transport.closed, "structured rejection keeps transport open");
        }
    }

    private static void predispatchInterruptionDoesNotScheduleCleanup() {
        FakeTransport transport = new FakeTransport();
        transport.blockPingSend = true;
        AtomicReference<Throwable> pingFailure = new AtomicReference<>();
        AtomicReference<Throwable> openFailure = new AtomicReference<>();
        try (Client client = client(transport, Duration.ofSeconds(2))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Thread blockedWriter = new Thread(() -> {
                try {
                    session.ping(Options.Read.defaults());
                } catch (Throwable error) {
                    pingFailure.set(error);
                }
            }, "cmux-predispatch-lock-holder");
            blockedWriter.start();
            require(
                transport.awaitBlockedPing(),
                "independent request holds the write lock"
            );
            Thread opener = failedOpenThread(
                session,
                openFailure,
                "cmux-predispatch-interrupted-open"
            );
            opener.start();
            sleep(Duration.ofMillis(50));
            opener.interrupt();
            join(opener, Duration.ofSeconds(1), "predispatch open");
            require(
                openFailure.get() instanceof TransportError &&
                    openFailure.get().getMessage().contains(
                        "interrupted while waiting to write"
                    ),
                "predispatch interruption remains the opening error"
            );
            require(
                transport.streamCancelCount() == 0,
                "predispatch interruption schedules no cleanup"
            );
            require(
                !transport.closed,
                "predispatch interruption keeps the connection open"
            );
            transport.releaseBlockedPingSend();
            join(blockedWriter, Duration.ofSeconds(1), "lock-holding ping");
            require(
                pingFailure.get() == null,
                "lock-holding request completes after release"
            );
            transport.blockPingSend = false;
            require(
                session.ping(Options.Read.defaults()).alive(),
                "client remains reusable after predispatch interruption"
            );
        }
    }

    private static void partialSiblingSendClosesWithoutAppendingCancel() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure = StreamOpenFailure.TIMEOUT;
        AtomicReference<Throwable> openFailure = new AtomicReference<>();
        try (Client client = client(transport, Duration.ofSeconds(5))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Thread opener = new Thread(() -> {
                try {
                    session.events(new Options.SessionEvents(
                        Options.Stream.defaults(),
                        Optional.empty()
                    ));
                } catch (Throwable error) {
                    openFailure.set(error);
                }
            }, "cmux-unacknowledged-open-before-partial-write");
            opener.start();
            require(
                transport.awaitFailedOpenDispatch(),
                "server observes unacknowledged stream open"
            );
            transport.failPingSend = true;
            TransportError partial = expect(
                TransportError.class,
                () -> session.ping(Options.Read.defaults())
            );
            require(
                partial.getCause() != null &&
                    partial.getCause().getMessage().contains(
                        "partial ping write"
                    ),
                "partial sibling write remains the reported error"
            );
            require(
                transport.awaitClosed(),
                "partial sibling write closes the transport"
            );
            join(opener, Duration.ofSeconds(1), "unacknowledged stream open");
            require(
                openFailure.get() instanceof TransportError,
                "unacknowledged open fails on disconnect"
            );
            require(
                transport.operationCount("stream.cancel") == 0,
                "partial sibling frame is not followed by stream cancellation"
            );
        }
    }

    private static void readerFailureDoesNotAppendCancelAfterPartialSiblingSend() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure = StreamOpenFailure.TIMEOUT;
        transport.blockThenFailPingSend = true;
        AtomicReference<Throwable> openFailure = new AtomicReference<>();
        AtomicReference<Throwable> pingFailure = new AtomicReference<>();
        try (Client client = client(transport, Duration.ofSeconds(5))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Thread opener = failedOpenThread(
                session,
                openFailure,
                "cmux-open-before-reader-partial-write-race"
            );
            opener.start();
            require(
                transport.awaitFailedOpenDispatch(),
                "server observes the unacknowledged stream open"
            );

            Thread ping = new Thread(() -> {
                try {
                    session.ping(Options.Read.defaults());
                } catch (Throwable error) {
                    pingFailure.set(error);
                }
            }, "cmux-partial-write-during-reader-failure");
            ping.start();
            require(
                transport.awaitBlockedPartialPing(),
                "sibling request reaches its partial write"
            );
            transport.injectProtocolFailure();

            long deadline = System.nanoTime() +
                TimeUnit.SECONDS.toNanos(1);
            while (!client.isClosed() && System.nanoTime() < deadline) {
                Thread.yield();
            }
            require(
                client.isClosed(),
                "reader failure starts connection shutdown"
            );
            transport.releaseBlockedPartialPingSend();

            join(ping, Duration.ofSeconds(2), "partial sibling request");
            join(opener, Duration.ofSeconds(2), "unacknowledged stream open");
            require(
                pingFailure.get() instanceof TransportError,
                "partial sibling write remains its request error"
            );
            require(
                openFailure.get() instanceof ProtocolError,
                "reader protocol failure remains the opening error"
            );
            require(
                transport.awaitClosed(),
                "framing-unsafe reader failure closes the transport"
            );
            require(
                transport.operationCount("stream.cancel") == 0,
                "reader cleanup does not append to the partial frame"
            );
        }
    }

    private static void streamOpenTransportFailureCancelsBeforeDisconnect() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure = StreamOpenFailure.TRANSPORT_ERROR;
        try (Client client = client(transport)) {
            ProtocolError failure = expect(
                ProtocolError.class,
                () -> client.machine(Selector.current())
                    .session(Selector.current())
                    .events(new Options.SessionEvents(
                        Options.Stream.defaults(),
                        Optional.empty()
                    ))
            );
            require(
                failure.getMessage().contains("unexpected server protocol"),
                "transport protocol failure remains the reported error"
            );
            require(
                transport.awaitFailedOpenCleanup(),
                "transport failure sends cleanup before closing"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "transport failure sends one untracked cleanup"
            );
        }
    }

    private static void failedOpenCleanupBlocksConnectionReuseUntilConfirmed() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure =
            StreamOpenFailure.MALFORMED_ACK_WITH_LATE_ITEM;
        transport.dropCleanupResponse = true;
        AtomicReference<Throwable> openFailure = new AtomicReference<>();
        AtomicReference<Throwable> pingFailure = new AtomicReference<>();
        try (Client client = client(transport, Duration.ofSeconds(5))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Thread opener = failedOpenThread(
                session,
                openFailure,
                "cmux-open-waits-for-cleanup-confirmation"
            );
            opener.start();
            require(
                transport.awaitStreamCancel(),
                "failed-open cleanup request is dispatched"
            );

            Thread ping = new Thread(() -> {
                try {
                    session.ping(Options.Read.defaults());
                } catch (Throwable error) {
                    pingFailure.set(error);
                }
            }, "cmux-request-behind-failed-open-cleanup");
            ping.start();
            sleep(Duration.ofMillis(50));
            require(
                opener.isAlive(),
                "failed open waits for cleanup confirmation"
            );
            require(
                ping.isAlive() &&
                    transport.operationCount("session.ping") == 0,
                "later request cannot overtake failed-open cleanup"
            );

            transport.releaseCleanupResponse();
            join(opener, Duration.ofSeconds(2), "failed stream open");
            join(ping, Duration.ofSeconds(2), "request after cleanup");
            require(
                openFailure.get() instanceof ProtocolError,
                "cleanup confirmation preserves the opening error"
            );
            require(
                pingFailure.get() == null,
                "connection is reusable after cleanup confirmation"
            );
            require(
                transport.operationCount("stream.cancel") == 1 &&
                    transport.operationCount("session.ping") == 1,
                "confirmed cleanup precedes the later request"
            );
            require(
                !transport.closed,
                "confirmed cleanup leaves framing-safe connection open"
            );
        }
    }

    private static void failedStreamOpenCleanupDeadlineDoesNotPoisonLaterRequests() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure = StreamOpenFailure.MALFORMED_ACK;
        transport.blockCleanupSend = true;
        try (Client client = client(transport, Duration.ofSeconds(5))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            ProtocolError original = expect(
                ProtocolError.class,
                () -> session.events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ))
            );
            require(
                original.getMessage().contains("malformed stream acknowledgment"),
                "blocked cleanup does not replace the opening error"
            );
            require(
                transport.awaitBlockedCleanup(),
                "cleanup transport write is blocked"
            );

            long started = System.nanoTime();
            TransportError later = expect(
                TransportError.class,
                () -> session.ping(Options.Read.defaults())
            );
            Duration elapsed = Duration.ofNanos(System.nanoTime() - started);
            require(
                elapsed.compareTo(Duration.ofSeconds(2)) < 0,
                "blocked cleanup bounds later writes: " + elapsed
            );
            require(
                later.getMessage().contains("timed out"),
                "cleanup deadline fails the poisoned connection"
            );
        }
    }

    private static void failedStreamOpenCleanupResponseTimeoutClosesConnection() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure = StreamOpenFailure.MALFORMED_ACK;
        transport.dropCleanupResponse = true;
        try (Client client = client(transport, Duration.ofSeconds(5))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            ProtocolError original = expect(
                ProtocolError.class,
                () -> session.events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ))
            );
            require(
                original.getMessage().contains("malformed stream acknowledgment"),
                "cleanup response timeout preserves the opening error"
            );
            require(
                transport.awaitFailedOpenCleanup(),
                "failed-open cancellation is dispatched"
            );
            require(
                transport.awaitClosed(),
                "missing cleanup response closes the connection"
            );

            long started = System.nanoTime();
            expect(
                TransportError.class,
                () -> session.ping(Options.Read.defaults())
            );
            require(
                Duration.ofNanos(System.nanoTime() - started)
                    .compareTo(Duration.ofMillis(100)) < 0,
                "request after cleanup timeout fails promptly"
            );
        }
    }

    private static void failedStreamOpenCleanupWriteLockTimeoutClosesConnection() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure =
            StreamOpenFailure.DELAYED_MALFORMED_ACK;
        transport.blockPingSend = true;
        AtomicReference<Throwable> openFailure = new AtomicReference<>();
        AtomicReference<Throwable> pingFailure = new AtomicReference<>();
        try (Client client = client(transport, Duration.ofSeconds(5))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Thread opener = new Thread(() -> {
                try {
                    session.events(new Options.SessionEvents(
                        Options.Stream.defaults(),
                        Optional.empty()
                    ));
                } catch (Throwable error) {
                    openFailure.set(error);
                }
            }, "cmux-delayed-malformed-open-test");
            opener.start();
            require(
                transport.awaitFailedOpenDispatch(),
                "delayed malformed open is dispatched"
            );

            Thread blockedWriter = new Thread(() -> {
                try {
                    session.ping(Options.Read.defaults());
                } catch (Throwable error) {
                    pingFailure.set(error);
                }
            }, "cmux-blocked-write-lock-test");
            blockedWriter.start();
            require(
                transport.awaitBlockedPing(),
                "an independent request holds the client write lock"
            );
            long started = System.nanoTime();
            transport.releaseDelayedMalformedAck();

            join(opener, Duration.ofSeconds(2), "failed stream open");
            join(blockedWriter, Duration.ofSeconds(2), "blocked writer");
            require(
                Duration.ofNanos(System.nanoTime() - started)
                    .compareTo(Duration.ofSeconds(2)) < 0,
                "write-lock cleanup fallback is bounded"
            );
            require(
                openFailure.get() instanceof ProtocolError &&
                    openFailure.get().getMessage().contains(
                        "malformed stream acknowledgment"
                    ),
                "write-lock timeout preserves the opening error"
            );
            require(
                pingFailure.get() instanceof TransportError,
                "connection close releases the blocked writer"
            );
            require(
                transport.awaitClosed(),
                "write-lock timeout closes the connection"
            );
            require(
                transport.operationCount("stream.cancel") == 0,
                "cleanup is not sent without write-lock ownership"
            );
        }
    }

    private static void transportFailureWaitsForInFlightDispatchMarker() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure =
            StreamOpenFailure.TRANSPORT_ERROR_BLOCKED_RETURN;
        AtomicReference<Throwable> failure = new AtomicReference<>();
        try (Client client = client(transport, Duration.ofSeconds(2))) {
            Thread opener = new Thread(() -> {
                try {
                    client.machine(Selector.current())
                        .session(Selector.current())
                        .events(new Options.SessionEvents(
                            Options.Stream.defaults(),
                            Optional.empty()
                        ));
                } catch (Throwable error) {
                    failure.set(error);
                }
            }, "cmux-blocked-stream-open-dispatch-test");
            opener.start();
            require(
                transport.awaitTransportFailureResponse(),
                "transport failure is visible before send returns"
            );
            sleep(Duration.ofMillis(50));
            transport.releaseBlockedOpenSend();
            try {
                opener.join(TimeUnit.SECONDS.toMillis(2));
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError("test interrupted", error);
            }
            require(!opener.isAlive(), "blocked stream open returns");
            require(
                failure.get() instanceof ProtocolError,
                "transport failure remains the opening error"
            );
            require(
                transport.awaitFailedOpenCleanup(),
                "pre-close cleanup observes the in-flight dispatch marker"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "transport failure sends exactly one cleanup"
            );
        }
    }

    private static void simultaneousBlockedCleanupsHaveIndependentDeadlines() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure =
            StreamOpenFailure.PAIRED_MALFORMED_ACKS;
        transport.blockCleanupSend = true;
        AtomicLong nextStream = new AtomicLong();
        AtomicReference<Throwable> firstFailure = new AtomicReference<>();
        AtomicReference<Throwable> secondFailure = new AtomicReference<>();
        try (Client client = Client.builder()
                .transport(transport)
                .timeout(Duration.ofSeconds(5))
                .idempotencyKeySource(() -> "idem-test")
                .streamIdSource(() -> String.format(
                    "stream_%032x",
                    nextStream.incrementAndGet()
                ))
                .build()) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            Thread first = failedOpenThread(
                session,
                firstFailure,
                "cmux-first-simultaneous-cleanup"
            );
            Thread second = failedOpenThread(
                session,
                secondFailure,
                "cmux-second-simultaneous-cleanup"
            );
            long started = System.nanoTime();
            first.start();
            second.start();
            join(first, Duration.ofSeconds(2), "first malformed stream open");
            join(second, Duration.ofSeconds(2), "second malformed stream open");
            require(
                firstFailure.get() instanceof ProtocolError &&
                    secondFailure.get() instanceof ProtocolError,
                "both simultaneous opens preserve malformed ACK errors"
            );
            require(
                transport.awaitBlockedCleanup(),
                "first cleanup blocks its dedicated worker"
            );
            require(
                transport.awaitClosed(),
                "independent deadline closes blocked cleanup transport"
            );
            require(
                Duration.ofNanos(System.nanoTime() - started)
                    .compareTo(Duration.ofSeconds(2)) < 0,
                "queued cleanup cannot extend the cleanup deadline"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "queued cleanup never creates a second blocked send"
            );
        }
    }

    private static void cleanupAdmissionIsBoundedAndFailClosesOnSaturation() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure =
            StreamOpenFailure.MANUAL_BATCH_MALFORMED_ACKS;
        transport.dropCleanupResponse = true;
        AtomicLong nextStream = new AtomicLong();
        int openCount =
            Client.FAILED_STREAM_OPEN_CLEANUP_QUEUE_CAPACITY + 2;
        transport.malformedAckBatchSize = openCount;
        try (Client client = Client.builder()
                .transport(transport)
                .timeout(Duration.ofSeconds(5))
                .idempotencyKeySource(() -> "idem-test")
                .streamIdSource(() -> String.format(
                    "stream_%032x",
                    nextStream.incrementAndGet()
                ))
                .build()) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            List<AtomicReference<Throwable>> failures = new ArrayList<>();
            List<Thread> openers = new ArrayList<>();
            for (int index = 0; index < openCount; index++) {
                AtomicReference<Throwable> failure = new AtomicReference<>();
                failures.add(failure);
                Thread opener = failedOpenThread(
                    session,
                    failure,
                    "cmux-saturated-cleanup-" + index
                );
                openers.add(opener);
                opener.start();
            }
            require(
                transport.awaitMalformedOpenBatch(openCount),
                "all failed opens are dispatched before cleanup starts"
            );
            transport.releaseMalformedOpenAcks(0, 1);
            require(
                transport.awaitStreamCancel(),
                "cleanup worker is blocked awaiting its response"
            );
            transport.releaseMalformedOpenAcks(1, openCount);
            for (int index = 0; index < openers.size(); index++) {
                join(
                    openers.get(index),
                    Duration.ofSeconds(3),
                    "saturated failed stream open " + index
                );
                require(
                    failures.get(index).get() instanceof ProtocolError,
                    "cleanup saturation preserves opening error " + index
                );
            }
            require(
                expect(
                    TransportError.class,
                    () -> session.ping(Options.Read.defaults())
                ).getMessage().contains(
                    "cannot schedule failed stream-open cleanup"
                ),
                "queue rejection is the terminal connection error"
            );
            require(
                transport.awaitClosed(),
                "cleanup admission rejection closes the transport"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "saturated cleanup queue starts only its blocked worker"
            );
            require(
                transport.operationCount("session.events") ==
                    openCount,
                "cleanup queue accepts only its fixed capacity"
            );
        }
    }

    private static Thread failedOpenThread(
        Session session,
        AtomicReference<Throwable> failure,
        String name
    ) {
        return new Thread(() -> {
            try {
                session.events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            } catch (Throwable error) {
                failure.set(error);
            }
        }, name);
    }

    private static void validAckBeforeTransportFailureDoesNotReturnDeadStream() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure =
            StreamOpenFailure.VALID_ACK_THEN_TRANSPORT_ERROR_BLOCKED_RETURN;
        AtomicReference<Throwable> failure = new AtomicReference<>();
        try (Client client = client(transport, Duration.ofSeconds(2))) {
            Thread opener = new Thread(() -> {
                try {
                    client.machine(Selector.current())
                        .session(Selector.current())
                        .events(new Options.SessionEvents(
                            Options.Stream.defaults(),
                            Optional.empty()
                        ));
                } catch (Throwable error) {
                    failure.set(error);
                }
            }, "cmux-valid-ack-before-transport-failure");
            opener.start();
            require(
                transport.awaitTransportFailureResponse(),
                "valid acknowledgment and transport failure are visible"
            );
            sleep(Duration.ofMillis(50));
            transport.releaseBlockedOpenSend();
            join(opener, Duration.ofSeconds(2), "valid-ack stream open");
            require(
                failure.get() instanceof ProtocolError,
                "closed client wins over the queued acknowledgment"
            );
            require(
                transport.awaitFailedOpenCleanup(),
                "transport failure cancels the acknowledged server route"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "valid-ack transport race sends one cleanup"
            );
        }
    }

    private static void malformedCorrelatedResponseCompletesOpenPromptly() {
        FakeTransport transport = new FakeTransport();
        transport.streamOpenFailure =
            StreamOpenFailure.MALFORMED_CORRELATED_RESPONSE;
        long started = System.nanoTime();
        try (Client client = client(transport, Duration.ofSeconds(5))) {
            expect(
                ProtocolError.class,
                () -> client.machine(Selector.current())
                    .session(Selector.current())
                    .events(new Options.SessionEvents(
                        Options.Stream.defaults(),
                        Optional.empty()
                    ))
            );
            require(
                Duration.ofNanos(System.nanoTime() - started)
                    .compareTo(Duration.ofSeconds(2)) < 0,
                "malformed correlated response does not wait for timeout"
            );
            require(
                transport.awaitFailedOpenCleanup(),
                "malformed correlated response cleans the dispatched open"
            );
            require(
                transport.awaitClosed(),
                "malformed correlated response closes the connection"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "malformed correlated response has one cleanup owner"
            );
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

    private static void explicitCancelWaitsForEndAfterResponse() {
        FakeTransport transport = new FakeTransport();
        transport.cancelableStream = true;
        transport.cancelEndMode = CancelEndMode.DELAYED_CANCELED;
        AtomicReference<Throwable> failure = new AtomicReference<>();
        try (Client client = client(transport, Duration.ofSeconds(1))) {
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.current())
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            Thread closer = new Thread(() -> {
                try {
                    stream.close();
                } catch (Throwable error) {
                    failure.set(error);
                }
            }, "cmux-explicit-cancel-awaits-end");
            closer.start();
            require(
                transport.awaitStreamCancel(),
                "explicit cancel response is dispatched"
            );
            sleep(Duration.ofMillis(50));
            require(
                closer.isAlive(),
                "cancel waits for stream_end after its response"
            );
            transport.releaseDelayedCancelEnd();
            join(closer, Duration.ofSeconds(1), "explicit cancel");
            require(
                failure.get() == null,
                "delayed canceled end completes explicit cancel"
            );
            require(
                stream.end().orElseThrow().reason().equals("canceled"),
                "explicit cancel retains the delayed server end"
            );
        }
    }

    private static void explicitCancelRejectsMalformedOrMissingEnd() {
        for (CancelEndMode mode : List.of(
                CancelEndMode.MISSING,
                CancelEndMode.WRONG_REASON,
                CancelEndMode.EXTRA_FIELD,
                CancelEndMode.NULL_CURSOR,
                CancelEndMode.NULL_RECOVERY,
                CancelEndMode.ERROR_ON_CANCELED,
                CancelEndMode.WRONG_STREAM_ID)) {
            FakeTransport transport = new FakeTransport();
            transport.cancelableStream = true;
            transport.cancelEndMode = mode;
            try (Client client = client(transport, Duration.ofMillis(150))) {
                ResourceStream<SessionEvent> stream = client
                    .machine(Selector.current())
                    .session(Selector.current())
                    .events(new Options.SessionEvents(
                        Options.Stream.defaults(),
                        Optional.empty()
                    ));
                RuntimeException failure = expect(
                    RuntimeException.class,
                    stream::close
                );
                boolean timesOut = mode == CancelEndMode.MISSING ||
                    mode == CancelEndMode.WRONG_STREAM_ID;
                require(
                    timesOut
                        ? failure instanceof TransportError
                        : failure instanceof ProtocolError,
                    "invalid cancel end has typed failure for " + mode +
                        ": " + failure
                );
                require(
                    transport.awaitClosed(),
                    "invalid cancel end closes connection for " + mode
                );
                requireRepeatedCloseFailure(
                    stream,
                    failure,
                    "invalid cancel end " + mode
                );
                require(
                    transport.operationCount("stream.cancel") == 1,
                    "invalid cancel end stays one-shot for " + mode
                );
            }
        }
    }

    private static void explicitCancelRejectsMalformedResponseEnvelope() {
        for (int variant = 0; variant < 2; variant++) {
            FakeTransport transport = new FakeTransport();
            transport.cancelableStream = true;
            transport.invalidCleanupEnvelopeExtra = variant == 0;
            transport.cleanupResponseResultAndError = variant == 1;
            try (Client client = client(transport)) {
                ResourceStream<SessionEvent> stream = client
                    .machine(Selector.current())
                    .session(Selector.current())
                    .events(new Options.SessionEvents(
                        Options.Stream.defaults(),
                        Optional.empty()
                    ));
                ProtocolError failure = expect(
                    ProtocolError.class,
                    stream::close
                );
                require(
                    transport.awaitClosed(),
                    "malformed cancel response closes connection"
                );
                requireRepeatedCloseFailure(
                    stream,
                    failure,
                    "malformed cancel response"
                );
                require(
                    transport.operationCount("stream.cancel") == 1,
                    "malformed cancel response stays one-shot"
                );
            }
        }
    }

    private static void explicitCancelRejectsMalformedKnownQueuedItem() {
        FakeTransport transport = new FakeTransport();
        transport.cancelableStream = true;
        transport.malformedKnownItemBeforeCancelEnd = true;
        try (Client client = client(transport)) {
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.current())
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            ProtocolError failure = expect(
                ProtocolError.class,
                stream::close
            );
            require(
                transport.awaitClosed(),
                "malformed known item during cancel closes connection"
            );
            requireRepeatedCloseFailure(
                stream,
                failure,
                "malformed queued item"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "malformed queued item cannot duplicate cancellation"
            );
        }
    }

    private static void explicitCancelRetainsDecoderAfterEndUntilResponse() {
        FakeTransport transport = new FakeTransport();
        transport.cancelableStream = true;
        transport.malformedKnownItemAfterCancelEnd = true;
        try (Client client = client(transport)) {
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.current())
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            ProtocolError failure = expect(
                ProtocolError.class,
                stream::close
            );
            require(
                transport.awaitClosed(),
                "cancel route remains typed after end until response"
            );
            requireRepeatedCloseFailure(
                stream,
                failure,
                "end-first malformed item"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "end-first malformed item cannot duplicate cancellation"
            );
        }
    }

    private static void explicitCancelRejectsValidItemAfterEnd() {
        FakeTransport transport = new FakeTransport();
        transport.cancelableStream = true;
        transport.validKnownItemAfterCancelEnd = true;
        try (Client client = client(transport)) {
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.current())
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            ProtocolError failure = expect(
                ProtocolError.class,
                stream::close
            );
            require(
                failure.getMessage().contains("followed stream_end"),
                "valid item after end is an ordering violation"
            );
            require(
                transport.awaitClosed(),
                "valid item after canceled end closes connection"
            );
            requireRepeatedCloseFailure(
                stream,
                failure,
                "valid item after canceled end"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "valid post-end item cannot duplicate cancellation"
            );
        }
    }

    private static void concurrentExplicitCancelCallersShareFailure() {
        FakeTransport transport = new FakeTransport();
        transport.cancelableStream = true;
        transport.dropCleanupResponse = true;
        try (Client client = client(transport, Duration.ofMillis(100))) {
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.current())
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            AtomicReference<RuntimeException> first =
                new AtomicReference<>();
            AtomicReference<RuntimeException> second =
                new AtomicReference<>();
            Thread firstCloser = closeCapturing(
                stream,
                first,
                "cmux-first-concurrent-cancel"
            );
            Thread secondCloser = closeCapturing(
                stream,
                second,
                "cmux-second-concurrent-cancel"
            );
            firstCloser.start();
            secondCloser.start();
            join(firstCloser, Duration.ofSeconds(1), "first cancel caller");
            join(secondCloser, Duration.ofSeconds(1), "second cancel caller");
            require(
                first.get() != null && first.get() == second.get(),
                "concurrent cancel callers receive the same failure instance"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "concurrent cancel callers share one wire attempt"
            );
        }
    }

    private static void explicitCancelBlockedSendHonorsTotalDeadline() {
        FakeTransport transport = new FakeTransport();
        transport.cancelableStream = true;
        transport.blockCleanupSend = true;
        try (Client client = client(transport, Duration.ofMillis(50))) {
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.current())
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            long started = System.nanoTime();
            TransportError failure = expect(
                TransportError.class,
                stream::close
            );
            require(
                Duration.ofNanos(System.nanoTime() - started)
                    .compareTo(Duration.ofSeconds(1)) < 0,
                "explicit cancel deadline includes blocked dispatch"
            );
            require(
                transport.awaitClosed(),
                "blocked explicit cancel closes the connection"
            );
            requireRepeatedCloseFailure(
                stream,
                failure,
                "blocked explicit cancel"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "blocked explicit cancel stays one-shot"
            );
        }
    }

    private static void overflowAndExplicitCloseShareOneCleanup() {
        FakeTransport transport = new FakeTransport();
        transport.overflowStream = true;
        try (Client client = client(transport)) {
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.current())
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            require(
                transport.awaitStreamCancel(),
                "overflow sends a bounded stream cancellation"
            );
            stream.close();
            sleep(Duration.ofMillis(25));
            require(
                transport.operationCount("stream.cancel") == 1,
                "overflow and explicit close share one cancellation claim"
            );
        }
    }

    private static void overflowInvalidCancelResultClosesWithoutDuplicate() {
        FakeTransport transport = new FakeTransport();
        transport.overflowStream = true;
        transport.invalidCleanupResult = true;
        try (Client client = client(transport)) {
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.current())
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            require(
                transport.awaitStreamCancel(),
                "overflow sends one stream cancellation"
            );
            require(
                transport.awaitClosed(),
                "invalid overflow cancellation result closes the connection"
            );
            stream.close();
            sleep(Duration.ofMillis(25));
            require(
                transport.operationCount("stream.cancel") == 1,
                "invalid overflow cleanup cannot be retried explicitly"
            );
        }
    }

    private static void overflowBlockedCancelHonorsTotalDeadline() {
        FakeTransport transport = new FakeTransport();
        transport.overflowStream = true;
        transport.blockCleanupSend = true;
        try (Client client = client(transport, Duration.ofMillis(200))) {
            ResourceStream<SessionEvent> stream = client
                .machine(Selector.current())
                .session(Selector.current())
                .events(new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                ));
            require(
                transport.awaitBlockedCleanup(),
                "overflow cancellation reaches blocked dispatch"
            );
            require(
                transport.awaitClosed(),
                "overflow cancellation dispatch obeys total deadline"
            );
            stream.close();
            require(
                transport.operationCount("stream.cancel") == 1,
                "blocked overflow cleanup stays one-shot"
            );
        }
    }

    private static void explicitCancelTimeoutClosesConnection() {
        FakeTransport transport = new FakeTransport();
        transport.cancelableStream = true;
        transport.dropCleanupResponse = true;
        try (Client client = client(transport, Duration.ofMillis(50))) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            ResourceStream<SessionEvent> stream = session.events(
                new Options.SessionEvents(
                    Options.Stream.defaults(),
                    Optional.empty()
                )
            );
            expect(TransportError.class, stream::close);
            require(
                transport.awaitClosed(),
                "explicit cancel timeout closes the connection"
            );
            require(
                transport.operationCount("stream.cancel") == 1,
                "explicit cancel timeout sends one cancellation"
            );
            long started = System.nanoTime();
            expect(
                TransportError.class,
                () -> session.ping(Options.Read.defaults())
            );
            require(
                Duration.ofNanos(System.nanoTime() - started)
                    .compareTo(Duration.ofMillis(100)) < 0,
                "request after explicit cancel failure is prompt"
            );
        }
    }

    private static Client client(FakeTransport transport) {
        return client(transport, Duration.ofSeconds(1));
    }

    private static Client client(
        FakeTransport transport,
        Duration timeout
    ) {
        return Client.builder()
            .transport(transport)
            .timeout(timeout)
            .idempotencyKeySource(() -> "idem-test")
            .streamIdSource(() -> "stream_" + HEX)
            .build();
    }

    private static Client waitClient(
        WaitCancelTransport transport,
        Duration timeout
    ) {
        return Client.builder()
            .transport(transport)
            .timeout(timeout)
            .build();
    }

    private static Terminal waitTerminal(Client client) {
        return client.machine(Selector.current())
            .session(Selector.current())
            .terminal(Selector.id(new Ids.TerminalId("term_" + HEX)));
    }

    private static Options.Wait waitOptions() {
        return new Options.Wait(
            Options.Read.defaults(),
            "ready",
            0
        );
    }

    private static Thread closeCapturing(
        ResourceStream<?> stream,
        AtomicReference<RuntimeException> failure,
        String name
    ) {
        return new Thread(() -> {
            try {
                stream.close();
            } catch (RuntimeException error) {
                failure.set(error);
            }
        }, name);
    }

    private static void requireRepeatedCloseFailure(
        ResourceStream<?> stream,
        RuntimeException expected,
        String context
    ) {
        RuntimeException repeated = expect(
            RuntimeException.class,
            stream::close
        );
        require(
            repeated == expected,
            context + " rethrows the identical cached failure"
        );
    }

    private static void sleep(Duration duration) {
        try {
            Thread.sleep(duration.toMillis());
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError("interrupted while holding an idle stream", error);
        }
    }

    private static void join(
        Thread thread,
        Duration timeout,
        String description
    ) {
        try {
            thread.join(timeout.toMillis());
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError(
                "interrupted while waiting for " + description,
                error
            );
        }
        require(!thread.isAlive(), description + " did not finish");
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

    private static final class WaitCancelTransport implements Transport {
        private final BlockingQueue<Map<String, Object>> inbound =
            new LinkedBlockingQueue<>();
        private final List<Map<String, Object>> sent = new ArrayList<>();
        private final CountDownLatch waitSent = new CountDownLatch(1);
        private final CountDownLatch requestCancelSent = new CountDownLatch(1);
        private volatile String waitRequestId;
        private volatile String cancelRequestId;
        private volatile boolean closed;
        private volatile boolean failWaitSend;

        @Override
        public void send(Map<String, Object> message) throws IOException {
            Map<String, Object> copy = new LinkedHashMap<>(message);
            synchronized (sent) {
                sent.add(copy);
            }
            String operation = String.valueOf(copy.get("operation"));
            String id = String.valueOf(copy.get("id"));
            Map<String, Object> params = object(copy.get("params"));
            switch (operation) {
                case "terminal.wait", "terminal.wait_exit" -> {
                    waitRequestId = id;
                    waitSent.countDown();
                    if (failWaitSend) {
                        throw new IOException(
                            "wait send failed after uncertain progress"
                        );
                    }
                }
                case "request.cancel" -> {
                    if (!String.valueOf(params.get("request_id"))
                            .equals(waitRequestId)) {
                        throw new IOException(
                            "request.cancel targeted the wrong request"
                        );
                    }
                    cancelRequestId = id;
                    requestCancelSent.countDown();
                }
                case "session.ping" -> inbound.add(success(
                    id,
                    Map.of(
                        "alive", true,
                        "cursor", Map.of(
                            "generation", "generation-1",
                            "revision", "1"
                        )
                    )
                ));
                default -> inbound.add(success(id, Map.of()));
            }
        }

        boolean awaitWait() {
            return await(waitSent, "terminal wait");
        }

        boolean awaitRequestCancel() {
            return await(requestCancelSent, "request.cancel");
        }

        void respondCancel(Map<String, Object> result) {
            String id = cancelRequestId;
            if (id == null) {
                throw new AssertionError("request.cancel is not pending");
            }
            inbound.add(success(id, result));
        }

        void respondTarget(Map<String, Object> result) {
            String id = waitRequestId;
            if (id == null) {
                throw new AssertionError("terminal wait is not pending");
            }
            inbound.add(success(id, result));
        }

        long operationCount(String operation) {
            synchronized (sent) {
                return sent.stream()
                    .filter(value -> operation.equals(value.get("operation")))
                    .count();
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

        private static boolean await(
            CountDownLatch latch,
            String description
        ) {
            try {
                return latch.await(1, TimeUnit.SECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError(
                    "interrupted waiting for " + description,
                    error
                );
            }
        }

        private static Map<String, Object> success(
            String id,
            Map<String, Object> result
        ) {
            return new LinkedHashMap<>(Map.of(
                "protocol", "cmux.protocol/2",
                "type", "response",
                "id", id,
                "ok", true,
                "result", result
            ));
        }
    }

    private enum CancelEndMode {
        CANCELED,
        DELAYED_CANCELED,
        MISSING,
        WRONG_REASON,
        EXTRA_FIELD,
        NULL_CURSOR,
        NULL_RECOVERY,
        ERROR_ON_CANCELED,
        WRONG_STREAM_ID
    }

    private enum StreamOpenFailure {
        NONE,
        TIMEOUT,
        MALFORMED_ACK,
        MALFORMED_ACK_WITH_LATE_ITEM,
        DELAYED_MALFORMED_ACK,
        MISMATCHED_ACK,
        REJECTED,
        PAIRED_MALFORMED_ACKS,
        MANUAL_BATCH_MALFORMED_ACKS,
        MALFORMED_CORRELATED_RESPONSE,
        TRANSPORT_ERROR,
        TRANSPORT_ERROR_BLOCKED_RETURN,
        VALID_ACK_THEN_TRANSPORT_ERROR_BLOCKED_RETURN
    }

    private static final class FakeTransport implements Transport {
        private final BlockingQueue<Map<String, Object>> inbound =
            new LinkedBlockingQueue<>();
        private final List<Map<String, Object>> sent = new ArrayList<>();
        private final CountDownLatch failedOpenDispatched = new CountDownLatch(1);
        private final CountDownLatch failedOpenCleaned = new CountDownLatch(1);
        private final CountDownLatch blockedCleanupStarted = new CountDownLatch(1);
        private final CountDownLatch releaseBlockedCleanup = new CountDownLatch(1);
        private final CountDownLatch transportFailureResponse =
            new CountDownLatch(1);
        private final CountDownLatch releaseOpenSend = new CountDownLatch(1);
        private final CountDownLatch blockedPingStarted = new CountDownLatch(1);
        private final CountDownLatch releaseBlockedPing = new CountDownLatch(1);
        private final CountDownLatch blockedPartialPingStarted =
            new CountDownLatch(1);
        private final CountDownLatch releaseBlockedPartialPing =
            new CountDownLatch(1);
        private final CountDownLatch transportClosed = new CountDownLatch(1);
        private final CountDownLatch streamCancelSent = new CountDownLatch(1);
        private final AtomicLong observedStreamCancels = new AtomicLong();
        private volatile boolean closed;
        private boolean failBrowserNavigate;
        private boolean failMutationTransport;
        private boolean failStreamOpenSend;
        private boolean failPingSend;
        private boolean blockCleanupSend;
        private boolean blockPingSend;
        private boolean blockThenFailPingSend;
        private boolean dropCleanupResponse;
        private boolean invalidCleanupResult;
        private boolean invalidCleanupEnvelopeExtra;
        private boolean cleanupResponseResultAndError;
        private boolean cancelableStream;
        private boolean malformedKnownItemBeforeCancelEnd;
        private boolean malformedKnownItemAfterCancelEnd;
        private boolean validKnownItemAfterCancelEnd;
        private boolean delayStreamEvent;
        private boolean invalidStreamItemExtra;
        private boolean overflowStream;
        private volatile StreamOpenFailure streamOpenFailure =
            StreamOpenFailure.NONE;
        private volatile String openStreamId;
        private volatile String failedOpenRequestId;
        private volatile String pendingCleanupRequestId;
        private volatile String delayedCancelStreamId;
        private CancelEndMode cancelEndMode = CancelEndMode.CANCELED;
        private boolean serverStreamActive;
        private int malformedAckBatchSize;
        private final List<Map<String, String>> pairedFailedOpens =
            new ArrayList<>();
        private final List<Map<String, String>> manualFailedOpens =
            new ArrayList<>();

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
            if (failStreamOpenSend && operation.equals("session.events")) {
                serverStreamActive = true;
                openStreamId = String.valueOf(params.get("stream_id"));
                throw new IOException(
                    "stream open failed after ambiguous write progress"
                );
            }
            if (blockPingSend && operation.equals("session.ping")) {
                blockedPingStarted.countDown();
                try {
                    releaseBlockedPing.await();
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    throw new IOException("ping send interrupted", error);
                }
                if (closed) {
                    throw new IOException("transport closed during ping");
                }
            }
            if (failPingSend && operation.equals("session.ping")) {
                throw new IOException("partial ping write failed");
            }
            if (blockThenFailPingSend && operation.equals("session.ping")) {
                blockedPartialPingStarted.countDown();
                try {
                    releaseBlockedPartialPing.await();
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    throw new IOException(
                        "partial ping send interrupted",
                        error
                    );
                }
                throw new IOException("blocked partial ping write failed");
            }
            if (operation.equals("stream.cancel")) {
                observedStreamCancels.incrementAndGet();
                if (blockCleanupSend) {
                    blockedCleanupStarted.countDown();
                    try {
                        releaseBlockedCleanup.await();
                    } catch (InterruptedException error) {
                        Thread.currentThread().interrupt();
                        throw new IOException("cleanup send interrupted", error);
                    }
                    if (closed) {
                        throw new IOException("transport closed during cleanup");
                    }
                }
                streamCancelSent.countDown();
                serverStreamActive = false;
                if (failedOpenRequestId != null) {
                    if (streamOpenFailure == StreamOpenFailure.TIMEOUT) {
                        inbound.add(response(
                            failedOpenRequestId,
                            true,
                            Map.of("stream_id", openStreamId),
                            Map.of()
                        ));
                    }
                    failedOpenRequestId = null;
                    failedOpenCleaned.countDown();
                }
                if (cancelableStream) {
                    if (malformedKnownItemBeforeCancelEnd) {
                        inbound.add(Map.of(
                            "protocol", "cmux.protocol/2",
                            "type", "stream_item",
                            "stream_id", openStreamId,
                            "sequence", "0",
                            "cursor", Map.of(
                                "generation", "generation-1",
                                "revision", "1"
                            ),
                            "item", Map.of("kind", "delta")
                        ));
                    }
                    if (cancelEndMode == CancelEndMode.DELAYED_CANCELED) {
                        delayedCancelStreamId = openStreamId;
                    } else if (cancelEndMode != CancelEndMode.MISSING) {
                        inbound.add(cancelEndEnvelope(
                            openStreamId,
                            cancelEndMode
                        ));
                    }
                    if (malformedKnownItemAfterCancelEnd) {
                        inbound.add(Map.of(
                            "protocol", "cmux.protocol/2",
                            "type", "stream_item",
                            "stream_id", openStreamId,
                            "sequence", "1",
                            "cursor", Map.of(
                                "generation", "generation-1",
                                "revision", "1"
                            ),
                            "item", Map.of("kind", "delta")
                        ));
                    }
                    if (validKnownItemAfterCancelEnd) {
                        Map<String, Object> cursor = Map.of(
                            "generation", "generation-1",
                            "revision", "1"
                        );
                        inbound.add(Map.of(
                            "protocol", "cmux.protocol/2",
                            "type", "stream_item",
                            "stream_id", openStreamId,
                            "sequence", "1",
                            "cursor", cursor,
                            "item", Map.of(
                                "kind", "delta",
                                "cursor", cursor,
                                "previous_revision", "0",
                                "revision", "1",
                                "changes", List.of()
                            )
                        ));
                    }
                }
                if (!dropCleanupResponse) {
                    Map<String, Object> cancelResponse = response(
                        id,
                        true,
                        invalidCleanupResult
                            ? Map.of("unexpected", true)
                            : Map.of(),
                        Map.of()
                    );
                    if (invalidCleanupEnvelopeExtra) {
                        cancelResponse.put("unexpected", true);
                    }
                    if (cleanupResponseResultAndError) {
                        cancelResponse.put("error", resourceError());
                    }
                    inbound.add(cancelResponse);
                } else {
                    pendingCleanupRequestId = id;
                }
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
            if (operation.equals("session.events")) {
                String streamId = String.valueOf(params.get("stream_id"));
                if (serverStreamActive &&
                        streamOpenFailure !=
                            StreamOpenFailure.PAIRED_MALFORMED_ACKS &&
                        streamOpenFailure !=
                            StreamOpenFailure.MANUAL_BATCH_MALFORMED_ACKS) {
                    inbound.add(response(
                        id,
                        false,
                        Map.of(),
                        Map.of(
                            "code", "stream.quota",
                            "message", "one stream is already active",
                            "details", Map.of(),
                            "retryable", true
                        )
                    ));
                    return;
                }
                if (streamOpenFailure == StreamOpenFailure.REJECTED) {
                    inbound.add(response(
                        id,
                        false,
                        Map.of(),
                        Map.of(
                            "code", "session.not_found",
                            "message", "session does not exist",
                            "details", Map.of(),
                            "retryable", false
                        )
                    ));
                    return;
                }
                serverStreamActive = true;
                openStreamId = streamId;
                if (streamOpenFailure != StreamOpenFailure.NONE) {
                    failedOpenRequestId = id;
                    failedOpenDispatched.countDown();
                    switch (streamOpenFailure) {
                        case TIMEOUT -> {
                            return;
                        }
                        case MALFORMED_ACK -> {
                            inbound.add(response(
                                id,
                                true,
                                Map.of("stream_id", 7),
                                Map.of()
                            ));
                            return;
                        }
                        case MALFORMED_ACK_WITH_LATE_ITEM -> {
                            inbound.add(response(
                                id,
                                true,
                                Map.of("stream_id", 7),
                                Map.of()
                            ));
                            inbound.add(Map.of(
                                "protocol", "cmux.protocol/2",
                                "type", "stream_item",
                                "stream_id", streamId,
                                "sequence", "0",
                                "cursor", Map.of(
                                    "generation", "generation-1",
                                    "revision", "0"
                                ),
                                "item", Map.of("kind", "late-pre-ack")
                            ));
                            return;
                        }
                        case MANUAL_BATCH_MALFORMED_ACKS -> {
                            manualFailedOpens.add(Map.of(
                                "id", id,
                                "stream_id", streamId
                            ));
                            if (manualFailedOpens.size() >
                                    malformedAckBatchSize) {
                                throw new AssertionError(
                                    "too many batched failed opens"
                                );
                            }
                            notifyAll();
                            return;
                        }
                        case MALFORMED_CORRELATED_RESPONSE -> {
                            inbound.add(Map.of(
                                "protocol", "cmux.protocol/2",
                                "type", "response",
                                "id", id,
                                "ok", "invalid",
                                "result", Map.of("stream_id", streamId)
                            ));
                            return;
                        }
                        case DELAYED_MALFORMED_ACK -> {
                            return;
                        }
                        case MISMATCHED_ACK -> {
                            inbound.add(response(
                                id,
                                true,
                                Map.of(
                                    "stream_id",
                                    "stream_ffffffffffffffffffffffffffffffff"
                                ),
                                Map.of()
                            ));
                            return;
                        }
                        case PAIRED_MALFORMED_ACKS -> {
                            pairedFailedOpens.add(Map.of(
                                "id", id,
                                "stream_id", streamId
                            ));
                            if (pairedFailedOpens.size() == 2) {
                                for (Map<String, String> failed :
                                        pairedFailedOpens) {
                                    inbound.add(response(
                                        failed.get("id"),
                                        true,
                                        Map.of("stream_id", 7),
                                        Map.of()
                                    ));
                                }
                            }
                            return;
                        }
                        case TRANSPORT_ERROR -> {
                            inbound.add(Map.of(
                                "protocol", "not-cmux",
                                "type", "response",
                                "id", id,
                                "ok", true,
                                "result", Map.of("stream_id", streamId)
                            ));
                            return;
                        }
                        case TRANSPORT_ERROR_BLOCKED_RETURN -> {
                            inbound.add(Map.of(
                                "protocol", "not-cmux",
                                "type", "response",
                                "id", id,
                                "ok", true,
                                "result", Map.of("stream_id", streamId)
                            ));
                            transportFailureResponse.countDown();
                            try {
                                releaseOpenSend.await();
                            } catch (InterruptedException error) {
                                Thread.currentThread().interrupt();
                                throw new IOException(
                                    "stream open interrupted",
                                    error
                                );
                            }
                            return;
                        }
                        case VALID_ACK_THEN_TRANSPORT_ERROR_BLOCKED_RETURN -> {
                            inbound.add(response(
                                id,
                                true,
                                Map.of("stream_id", streamId),
                                Map.of()
                            ));
                            inbound.add(Map.of(
                                "protocol", "not-cmux",
                                "type", "response",
                                "id", id,
                                "ok", true,
                                "result", Map.of("stream_id", streamId)
                            ));
                            transportFailureResponse.countDown();
                            try {
                                releaseOpenSend.await();
                            } catch (InterruptedException error) {
                                Thread.currentThread().interrupt();
                                throw new IOException(
                                    "stream open interrupted",
                                    error
                                );
                            }
                            return;
                        }
                        default -> throw new AssertionError(
                            "unexpected stream failure " + streamOpenFailure
                        );
                    }
                }
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
                case "session.ping" -> Map.of(
                    "alive", true,
                    "cursor", Map.of(
                        "generation", "generation-1",
                        "revision", "1"
                    )
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
                if (cancelableStream || delayStreamEvent) {
                    return;
                }
                if (overflowStream) {
                    for (int index = 0;
                            index <= Client.MAX_STREAM_MESSAGES;
                            index++) {
                        inbound.add(Map.of(
                            "protocol", "cmux.protocol/2",
                            "type", "stream_item",
                            "stream_id", streamId,
                            "sequence", String.valueOf(index),
                            "cursor", Map.of(
                                "generation", "generation-1",
                                "revision", String.valueOf(index)
                            ),
                            "item", Map.of(
                                "kind", "future-session-item",
                                "index", index
                            )
                        ));
                    }
                    return;
                }
                enqueueSessionEvent(streamId, "preserved");
                serverStreamActive = false;
            }
        }

        boolean awaitFailedOpenDispatch() {
            try {
                return failedOpenDispatched.await(1, TimeUnit.SECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError("interrupted waiting for stream open", error);
            }
        }

        boolean awaitFailedOpenCleanup() {
            try {
                return failedOpenCleaned.await(1, TimeUnit.SECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError("interrupted waiting for cleanup", error);
            }
        }

        boolean awaitBlockedCleanup() {
            try {
                return blockedCleanupStarted.await(1, TimeUnit.SECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError("interrupted waiting for cleanup", error);
            }
        }

        boolean awaitTransportFailureResponse() {
            try {
                return transportFailureResponse.await(1, TimeUnit.SECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError(
                    "interrupted waiting for transport failure",
                    error
                );
            }
        }

        void releaseBlockedOpenSend() {
            releaseOpenSend.countDown();
        }

        void releaseBlockedPingSend() {
            releaseBlockedPing.countDown();
        }

        boolean awaitBlockedPing() {
            try {
                return blockedPingStarted.await(1, TimeUnit.SECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError(
                    "interrupted waiting for blocked ping",
                    error
                );
            }
        }

        boolean awaitBlockedPartialPing() {
            try {
                return blockedPartialPingStarted.await(
                    1,
                    TimeUnit.SECONDS
                );
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError(
                    "interrupted waiting for partial ping",
                    error
                );
            }
        }

        void releaseBlockedPartialPingSend() {
            releaseBlockedPartialPing.countDown();
        }

        void injectProtocolFailure() {
            inbound.add(Map.of(
                "protocol", "not-cmux",
                "type", "response",
                "id", "unrelated",
                "ok", true,
                "result", Map.of()
            ));
        }

        synchronized boolean awaitMalformedOpenBatch(int expected) {
            long deadline = System.nanoTime() +
                TimeUnit.SECONDS.toNanos(2);
            while (manualFailedOpens.size() < expected) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0L) {
                    return false;
                }
                try {
                    TimeUnit.NANOSECONDS.timedWait(this, remaining);
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    throw new AssertionError(
                        "interrupted waiting for malformed open batch",
                        error
                    );
                }
            }
            return true;
        }

        synchronized void releaseMalformedOpenAcks(
            int start,
            int end
        ) {
            for (int index = start; index < end; index++) {
                Map<String, String> failed = manualFailedOpens.get(index);
                inbound.add(response(
                    failed.get("id"),
                    true,
                    Map.of("stream_id", 7),
                    Map.of()
                ));
            }
        }

        synchronized void releaseCleanupResponse() {
            if (pendingCleanupRequestId == null) {
                throw new AssertionError("no cleanup response is pending");
            }
            inbound.add(response(
                pendingCleanupRequestId,
                true,
                Map.of(),
                Map.of()
            ));
            pendingCleanupRequestId = null;
        }

        synchronized void releaseDelayedCancelEnd() {
            if (delayedCancelStreamId == null) {
                throw new AssertionError("no delayed cancel end is pending");
            }
            inbound.add(cancelEndEnvelope(
                delayedCancelStreamId,
                CancelEndMode.CANCELED
            ));
            delayedCancelStreamId = null;
        }

        void releaseDelayedMalformedAck() {
            String requestId = failedOpenRequestId;
            if (requestId == null) {
                throw new AssertionError("no delayed malformed acknowledgment");
            }
            inbound.add(response(
                requestId,
                true,
                Map.of("stream_id", 7),
                Map.of()
            ));
        }

        boolean awaitClosed() {
            try {
                return transportClosed.await(2, TimeUnit.SECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError(
                    "interrupted waiting for transport close",
                    error
                );
            }
        }

        boolean awaitStreamCancel() {
            try {
                return streamCancelSent.await(2, TimeUnit.SECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError(
                    "interrupted waiting for stream cancellation",
                    error
                );
            }
        }

        synchronized void releaseDelayedStreamEvent() {
            if (!delayStreamEvent || openStreamId == null) {
                throw new AssertionError("no delayed stream event is pending");
            }
            delayStreamEvent = false;
            enqueueSessionEvent(openStreamId, "delayed");
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
            serverStreamActive = false;
            releaseBlockedCleanup.countDown();
            releaseOpenSend.countDown();
            releaseBlockedPing.countDown();
            releaseBlockedPartialPing.countDown();
            transportClosed.countDown();
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

        long streamCancelCount() {
            return observedStreamCancels.get();
        }

        private void enqueueSessionEvent(
            String streamId,
            String marker
        ) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("protocol", "cmux.protocol/2");
            item.put("type", "stream_item");
            item.put("stream_id", streamId);
            item.put("sequence", "18446744073709551615");
            item.put("cursor", Map.of(
                "generation", "generation-1",
                "revision", "18446744073709551615"
            ));
            item.put("item", Map.of(
                "kind", "future-session-item",
                "new_field", marker
            ));
            if (invalidStreamItemExtra) {
                item.put("unexpected", true);
            }
            inbound.add(item);
            inbound.add(Map.of(
                "protocol", "cmux.protocol/2",
                "type", "stream_end",
                "stream_id", streamId,
                "reason", "completed"
            ));
        }

        private static Map<String, Object> cancelEndEnvelope(
            String streamId,
            CancelEndMode mode
        ) {
            Map<String, Object> end = new LinkedHashMap<>();
            end.put("protocol", "cmux.protocol/2");
            end.put("type", "stream_end");
            end.put(
                "stream_id",
                mode == CancelEndMode.WRONG_STREAM_ID
                    ? "stream_ffffffffffffffffffffffffffffffff"
                    : streamId
            );
            end.put(
                "reason",
                mode == CancelEndMode.WRONG_REASON
                    ? "completed"
                    : "canceled"
            );
            if (mode == CancelEndMode.EXTRA_FIELD) {
                end.put("unexpected", true);
            } else if (mode == CancelEndMode.NULL_CURSOR) {
                end.put("cursor", null);
            } else if (mode == CancelEndMode.NULL_RECOVERY) {
                end.put("recovery", null);
            } else if (mode == CancelEndMode.ERROR_ON_CANCELED) {
                end.put("error", resourceError());
            }
            return end;
        }

        private static Map<String, Object> resourceError() {
            return Map.of(
                "code", "stream.failed",
                "message", "stream failed",
                "details", Map.of(),
                "retryable", false
            );
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
            value.put("protocol", "cmux.protocol/2");
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
