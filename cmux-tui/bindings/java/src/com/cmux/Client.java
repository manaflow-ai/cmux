package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.UnixTransport;
import com.cmux.internal.Wire;
import com.cmux.raw.SocketDiscovery;
import java.io.IOException;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Supplier;

/** Dependency-free Java 17 resource API client. */
public final class Client implements AutoCloseable {
    public static final int MAX_REQUEST_BYTES = 4 * 1024 * 1024;
    public static final int MAX_RESPONSE_BYTES = 16 * 1024 * 1024;
    public static final int MAX_STREAM_MESSAGES = 256;
    public static final int MAX_STREAM_BYTES = 16 * 1024 * 1024;

    @FunctionalInterface
    interface Decoder<T> {
        T decode(Object value);
    }

    record StreamMessage(Map<String, Object> envelope, RuntimeException error, int size) {}

    static final class StreamRoute {
        private final ArrayBlockingQueue<StreamMessage> messages =
            new ArrayBlockingQueue<>(MAX_STREAM_MESSAGES + 1);
        private final Map<String, Object> cancelParams;
        private int queuedBytes;
        private boolean accepting = true;
        private boolean terminated;

        StreamRoute(Map<String, Object> cancelParams) {
            this.cancelParams = Map.copyOf(cancelParams);
        }

        synchronized boolean deliver(StreamMessage message) {
            if (!accepting || terminated) {
                return false;
            }
            boolean end = "stream_end".equals(message.envelope().get("type"));
            if (!end && (messages.size() >= MAX_STREAM_MESSAGES ||
                    queuedBytes + message.size() > MAX_STREAM_BYTES)) {
                return false;
            }
            if (end) {
                accepting = false;
            }
            if (!messages.offer(message)) {
                return false;
            }
            queuedBytes += message.size();
            return true;
        }

        synchronized void finish(RuntimeException error) {
            if (terminated) {
                return;
            }
            accepting = false;
            terminated = true;
            messages.clear();
            queuedBytes = 0;
            messages.offer(new StreamMessage(Map.of(), error, 0));
        }

        synchronized void overflow() {
            finish(new StreamEndError(
                "gap",
                Optional.empty(),
                Optional.of(new ResourceError(
                    "stream.local_overflow",
                    "local stream queue exceeded its bounded capacity",
                    Map.of(
                        "message_limit", MAX_STREAM_MESSAGES,
                        "byte_limit", MAX_STREAM_BYTES
                    ),
                    true
                )),
                Optional.of("open a fresh stream to receive a new snapshot")
            ));
        }

        synchronized Optional<StreamEndError> cancelTerminal() {
            accepting = false;
            terminated = true;
            StreamEndError end = null;
            StreamMessage message;
            while ((message = messages.poll()) != null) {
                if ("stream_end".equals(message.envelope().get("type"))) {
                    end = decodeStreamEnd(message.envelope());
                } else if (message.error() instanceof StreamEndError candidate) {
                    end = candidate;
                }
            }
            queuedBytes = 0;
            return Optional.ofNullable(end);
        }

        StreamMessage poll(long timeout, TimeUnit unit) throws InterruptedException {
            StreamMessage message = messages.poll(timeout, unit);
            if (message != null) {
                synchronized (this) {
                    queuedBytes = Math.max(0, queuedBytes - message.size());
                }
            }
            return message;
        }
    }

    private final Transport transport;
    private final Duration timeout;
    private final Supplier<String> idempotencyKeys;
    private final Supplier<String> streamIds;
    private final AtomicLong nextRequest = new AtomicLong();
    private final AtomicBoolean closed = new AtomicBoolean();
    private final ConcurrentHashMap<String, CompletableFuture<Object>> pending =
        new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Ids.StreamId, StreamRoute> streams =
        new ConcurrentHashMap<>();
    private final Object writeLock = new Object();
    private final Thread reader;
    private volatile RuntimeException connectionError;

    private Client(Builder builder) {
        timeout = positive(builder.timeout, "timeout");
        idempotencyKeys = builder.idempotencyKeys == null
            ? randomSource("idem_")
            : builder.idempotencyKeys;
        streamIds = builder.streamIds == null
            ? randomSource("stream_")
            : builder.streamIds;
        if (builder.transport != null) {
            transport = builder.transport;
        } else {
            Path socket = SocketDiscovery.resolve(builder.socket, builder.session);
            try {
                transport = new UnixTransport(
                    socket,
                    builder.maxRequestBytes,
                    builder.maxResponseBytes
                );
            } catch (IOException | UnsupportedOperationException error) {
                throw new TransportError(
                    "cannot connect to Unix session socket " + socket +
                        "; inject a Transport on platforms without Unix-domain sockets",
                    error
                );
            }
        }
        reader = new Thread(this::readLoop, "cmux-resource-api-reader");
        reader.setDaemon(true);
        reader.start();
    }

    public static Builder builder() {
        return new Builder();
    }

    public Duration timeout() {
        return timeout;
    }

    public Machine machine(Selector<Ids.MachineId> selector) {
        return new Machine(this, selector);
    }

    public ProviderScope providerScope(Selector<Ids.ProviderScopeId> selector) {
        return new ProviderScope(this, selector);
    }

    public List<ProviderScope> listProviderScopes(Options.Read options) {
        Object result = requestValue(
            Operations.PROVIDER_SCOPE_LIST,
            copy(options == null ? Map.of() : options.extra()),
            null
        );
        List<ProviderScope> scopes = new ArrayList<>();
        for (Object value : listPayload(result, "provider scopes")) {
            Snapshots.ProviderScopeSnapshot decoded = decodeProviderScope(value);
            scopes.add(new ProviderScope(
                this,
                Selector.current(),
                Selector.id(decoded.id()),
                decoded
            ));
        }
        return List.copyOf(scopes);
    }

    public List<Machine> listMachines(Options.Read options) {
        Object result = requestValue(
            Operations.MACHINE_LIST,
            copy(options == null ? Map.of() : options.extra()),
            null
        );
        List<Object> values = listPayload(result, "machines");
        List<Machine> machines = new ArrayList<>(values.size());
        for (Object value : values) {
            Snapshots.MachineSnapshot snapshot = decodeMachine(value);
            machines.add(new Machine(this, Selector.id(snapshot.id()), snapshot));
        }
        return List.copyOf(machines);
    }

    public List<Machine> findMachinesByName(String name) {
        Objects.requireNonNull(name, "name");
        return listMachines(Options.Read.defaults()).stream()
            .filter(machine -> machine.cached()
                .map(Snapshots.MachineSnapshot::name)
                .map(name::equals)
                .orElse(false))
            .toList();
    }

    public MutationResult<Machine> createMachine(Options.MachineCreate options) {
        return providerScope(Selector.current()).createMachine(options);
    }

    public MutationResult<Machine> connectExternalMachine(
        Options.MachineConnectExternal options
    ) {
        return providerScope(Selector.current()).connectExternalMachine(options);
    }

    Map<String, Object> request(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation mutation
    ) {
        return Wire.object(
            requestValue(operation, params, mutation),
            operation.wireName() + " result"
        );
    }

    Object requestValue(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation mutation
    ) {
        ensureOpen();
        boolean isMutation = operation.operationClass() == Operations.Class.MUTATION;
        if (isMutation != (mutation != null)) {
            throw new IllegalArgumentException(
                operation.wireName() + (isMutation
                    ? " requires mutation options"
                    : " forbids mutation options")
            );
        }
        String requestId = "java-" + nextRequest.incrementAndGet();
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("protocol", Wire.PROTOCOL);
        envelope.put("type", "request");
        envelope.put("id", requestId);
        envelope.put("operation", operation.wireName());
        Map<String, Object> encodedParams = copy(params);
        if (mutation != null) {
            mutation.expectedRevision().ifPresent(
                revision -> encodedParams.put("expected_revision", revision)
            );
        }
        envelope.put("params", Wire.encode(encodedParams));
        if (mutation != null) {
            String key = mutation.idempotencyKey().orElseGet(idempotencyKeys);
            if (key.isEmpty() || key.length() > 128) {
                throw new IllegalArgumentException(
                    "idempotency key must contain 1 to 128 characters"
                );
            }
            envelope.put(Wire.IDEMPOTENCY_KEY, key);
        }
        CompletableFuture<Object> future = new CompletableFuture<>();
        pending.put(requestId, future);
        if (closed.get()) {
            pending.remove(requestId, future);
            throw closedError();
        }
        try {
            synchronized (writeLock) {
                transport.send(envelope);
            }
        } catch (IOException | RuntimeException error) {
            pending.remove(requestId);
            throw transportError("cannot send " + operation.wireName(), error);
        }
        try {
            return future.get(Math.max(1L, timeout.toMillis()), TimeUnit.MILLISECONDS);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            pending.remove(requestId);
            throw new TransportError("interrupted while waiting for " + operation.wireName(), error);
        } catch (TimeoutException error) {
            pending.remove(requestId);
            throw new TransportError(operation.wireName() + " timed out", error);
        } catch (ExecutionException error) {
            Throwable cause = error.getCause();
            if (cause instanceof RuntimeException runtime) {
                throw runtime;
            }
            throw new TransportError(operation.wireName() + " failed", cause);
        }
    }

    <T> ResourceStream<T> openStream(
        Operations operation,
        Map<String, Object> params,
        Decoder<T> decoder
    ) {
        Ids.StreamId streamId = new Ids.StreamId(streamIds.get());
        Map<String, Object> input = copy(params);
        Map<String, Object> cancelParams = Wire.map();
        for (String key : List.of(Wire.MACHINE, Wire.SESSION)) {
            if (input.containsKey(key)) {
                cancelParams.put(key, input.get(key));
            }
        }
        cancelParams.put("stream", streamId);
        StreamRoute route = new StreamRoute(cancelParams);
        streams.put(streamId, route);
        input.put(Wire.STREAM_ID, streamId);
        try {
            request(operation, input, null);
        } catch (RuntimeException error) {
            streams.remove(streamId);
            route.finish(error);
            throw error;
        }
        return new ResourceStream<>(this, streamId, route, decoder);
    }

    Optional<StreamEndError> cancelStream(
        Ids.StreamId streamId,
        StreamRoute route
    ) {
        try {
            Map<String, Object> result = request(
                Operations.STREAM_CANCEL,
                route.cancelParams,
                null
            );
            requireExactFields(result, "stream cancel result");
        } finally {
            streams.remove(streamId, route);
        }
        return route.cancelTerminal();
    }

    @Override
    public void close() {
        if (!closed.compareAndSet(false, true)) {
            return;
        }
        try {
            transport.close();
        } catch (IOException error) {
            connectionError = new TransportError("cannot close transport", error);
        }
        fail(connectionError == null
            ? new TransportError("client is closed")
            : connectionError);
    }

    private void readLoop() {
        try {
            while (!closed.get()) {
                Map<String, Object> envelope = transport.receive();
                if (!Wire.PROTOCOL.equals(envelope.get("protocol"))) {
                    throw new ProtocolError("unexpected server protocol");
                }
                String type = Wire.string(envelope.get("type"), "envelope type");
                if ("response".equals(type)) {
                    deliverResponse(envelope);
                } else if ("stream_item".equals(type) || "stream_end".equals(type)) {
                    deliverStream(envelope);
                } else {
                    throw new ProtocolError("unexpected envelope type " + type);
                }
            }
        } catch (IOException | RuntimeException error) {
            if (!closed.get()) {
                fail(transportError("resource transport failed", error));
            }
        }
    }

    private void deliverResponse(Map<String, Object> envelope) {
        String id = Wire.string(envelope.get("id"), "response id");
        CompletableFuture<Object> future = pending.remove(id);
        if (future == null) {
            return;
        }
        if (!Wire.bool(envelope.get("ok"), "response ok")) {
            future.completeExceptionally(decodeResourceError(envelope.get("error")));
            return;
        }
        if (!envelope.containsKey("result")) {
            future.completeExceptionally(
                new ProtocolError("successful response omitted result")
            );
            return;
        }
        future.complete(envelope.get("result"));
    }

    private void deliverStream(Map<String, Object> envelope) {
        Ids.StreamId id = new Ids.StreamId(
            Wire.string(envelope.get(Wire.STREAM_ID), "stream id")
        );
        StreamRoute route = streams.get(id);
        if (route == null) {
            return;
        }
        if ("stream_end".equals(envelope.get("type"))) {
            streams.remove(id, route);
        }
        int size = Wire.json(envelope).getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
        if (route.deliver(new StreamMessage(Map.copyOf(envelope), null, size))) {
            return;
        }
        streams.remove(id, route);
        route.overflow();
        CompletableFuture.runAsync(() -> {
            try {
                request(Operations.STREAM_CANCEL, route.cancelParams, null);
            } catch (RuntimeException ignored) {
                // The affected stream has already ended locally.
            }
        });
    }

    private void fail(RuntimeException error) {
        connectionError = error;
        if (closed.compareAndSet(false, true)) {
            try {
                transport.close();
            } catch (IOException closeError) {
                error.addSuppressed(closeError);
            }
        }
        for (CompletableFuture<Object> future : pending.values()) {
            future.completeExceptionally(error);
        }
        pending.clear();
        for (StreamRoute route : streams.values()) {
            route.finish(error);
        }
        streams.clear();
    }

    private void ensureOpen() {
        if (closed.get()) {
            throw closedError();
        }
    }

    private RuntimeException closedError() {
        return connectionError == null
            ? new TransportError("client is closed")
            : connectionError;
    }

    static Cursor decodeCursor(Object value) {
        if (value == null) {
            return null;
        }
        Map<String, Object> cursor = Wire.object(value, "cursor");
        requireExactFields(
            cursor,
            "cursor",
            Wire.GENERATION,
            Wire.REVISION
        );
        String generation = Wire.string(
            cursor.get(Wire.GENERATION),
            "cursor generation"
        );
        if (generation.isEmpty()) {
            throw new ProtocolError("cursor generation must not be empty");
        }
        return new Cursor(
            generation,
            Wire.decimal(cursor.get(Wire.REVISION), "cursor revision")
        );
    }

    static StreamEndError decodeStreamEnd(Map<String, Object> envelope) {
        Optional<ResourceError> error = envelope.get("error") == null
            ? Optional.empty()
            : Optional.of(decodeResourceError(envelope.get("error")));
        return new StreamEndError(
            Wire.string(envelope.get("reason"), "stream end reason"),
            Optional.ofNullable(decodeCursor(envelope.get(Wire.CURSOR))),
            error,
            Optional.ofNullable((String) envelope.get("recovery"))
        );
    }

    static ResourceError decodeResourceError(Object value) {
        Map<String, Object> error = Wire.object(value, "resource error");
        Object details = error.get(Wire.DETAILS);
        return new ResourceError(
            Wire.string(error.get("code"), "error code"),
            Wire.string(error.get("message"), "error message"),
            details == null ? Map.of() : Wire.object(details, "error details"),
            Wire.bool(error.get("retryable"), "error retryable")
        );
    }

    static Map<String, Object> copy(Map<String, Object> value) {
        return new LinkedHashMap<>(value == null ? Map.of() : value);
    }

    static Map<String, Object> selectors(Object... pairs) {
        Map<String, Object> result = Wire.map();
        for (int index = 0; index < pairs.length; index += 2) {
            Object selector = pairs[index + 1];
            if (selector != null) {
                result.put((String) pairs[index], selector);
            }
        }
        return result;
    }

    static void command(Map<String, Object> params, Command command) {
        params.putAll(command.toWire());
    }

    static Document document(Map<String, Object> value) {
        return new Document(value);
    }

    static List<Object> listPayload(Object result, String field) {
        return Wire.array(result, field);
    }

    static Map<String, Object> resourcePayload(Map<String, Object> result, String field) {
        Object value = result.get(field);
        if (value == null) {
            value = result.get("value");
        }
        return value instanceof Map<?, ?>
            ? Wire.object(value, field)
            : result;
    }

    static MutationParts mutationParts(Map<String, Object> result) {
        for (String key : result.keySet()) {
            if (!List.of(
                    Wire.VALUE,
                    Wire.GENERATION,
                    Wire.REVISION,
                    "replayed"
                ).contains(key)) {
                throw new ProtocolError(
                    "mutation result has unknown field " + key
                );
            }
        }
        if (!result.containsKey(Wire.VALUE) ||
                !result.containsKey(Wire.GENERATION) ||
                !result.containsKey(Wire.REVISION) ||
                !result.containsKey("replayed")) {
            throw new ProtocolError(
                "mutation result requires value, generation, revision, and replayed"
            );
        }
        String generation = Wire.string(
            result.get(Wire.GENERATION),
            "mutation generation"
        );
        if (generation.isEmpty()) {
            throw new ProtocolError("mutation generation must not be empty");
        }
        Decimal revision = Wire.decimal(
            result.get(Wire.REVISION),
            "mutation revision"
        );
        boolean replayed = Wire.bool(
            result.get("replayed"),
            "mutation replayed"
        );
        return new MutationParts(generation, revision, replayed);
    }

    record MutationParts(
        String generation,
        Decimal revision,
        boolean replayed
    ) {
        <T> MutationResult<T> withValue(T value) {
            return new MutationResult<>(value, generation, revision, replayed);
        }
    }

    record MutationResponse(Map<String, Object> result, MutationParts parts) {}

    MutationResponse mutation(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Map<String, Object> result = request(operation, params, options);
        return new MutationResponse(result, mutationParts(result));
    }

    static CreatedPath decodeCreatedPath(Map<String, Object> result) {
        Map<String, Object> path = Wire.object(result.get(Wire.VALUE), "created path");
        return new CreatedPath(
            optionalId(path, Wire.MACHINE, Ids.MachineId::new),
            optionalId(path, Wire.SESSION, Ids.SessionId::new),
            optionalId(path, Wire.WORKSPACE, Ids.WorkspaceId::new),
            optionalId(path, Wire.SCREEN, Ids.ScreenId::new),
            optionalId(path, Wire.PANE, Ids.PaneId::new),
            optionalId(path, Wire.TAB, Ids.TabId::new),
            optionalId(path, Wire.TERMINAL, Ids.TerminalId::new),
            optionalId(path, Wire.BROWSER, Ids.BrowserId::new)
        );
    }

    static EmptyResult decodeEmptyMutation(Map<String, Object> result) {
        Map<String, Object> value = Wire.object(
            result.get(Wire.VALUE),
            "empty mutation value"
        );
        requireExactFields(value, "empty mutation value");
        return new EmptyResult();
    }

    static Snapshots.MachineSnapshot decodeMachine(Object value) {
        Map<String, Object> fields = Wire.object(value, "machine snapshot");
        return new Snapshots.MachineSnapshot(
            new Ids.MachineId(Wire.string(fields.get("id"), "machine id")),
            Wire.string(fields.get(Wire.NAME), "machine name"),
            Wire.string(fields.get("origin"), "machine origin"),
            Wire.string(fields.get("status"), "machine status"),
            Wire.bool(fields.get("connectable"), "machine connectable"),
            optionalExactId(
                fields,
                "provider_scope_id",
                Ids.ProviderScopeId::new
            ),
            Wire.bool(fields.get("deleted"), "machine deleted"),
            Wire.bool(fields.get("recoverable"), "machine recoverable"),
            snapshotExtra(
                fields,
                "id",
                Wire.NAME,
                "origin",
                "status",
                "connectable",
                "provider_scope_id",
                "deleted",
                "recoverable"
            )
        );
    }

    static Snapshots.SessionSnapshot decodeSession(Object value) {
        Map<String, Object> fields = Wire.object(value, "session snapshot");
        return new Snapshots.SessionSnapshot(
            new Ids.SessionId(Wire.string(fields.get("id"), "session id")),
            requiredExactId(fields, "machine_id", Ids.MachineId::new),
            optionalString(fields, Wire.NAME),
            Wire.string(fields.get(Wire.GENERATION), "session generation"),
            Wire.decimal(fields.get(Wire.REVISION), "session revision"),
            Wire.bool(fields.get("connected"), "session connected"),
            snapshotExtra(
                fields,
                "id",
                "machine_id",
                Wire.NAME,
                Wire.GENERATION,
                Wire.REVISION,
                "connected"
            )
        );
    }

    static Snapshots.WorkspaceSnapshot decodeWorkspace(Object value) {
        Map<String, Object> fields = Wire.object(value, "workspace snapshot");
        return new Snapshots.WorkspaceSnapshot(
            new Ids.WorkspaceId(Wire.string(fields.get("id"), "workspace id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            Wire.string(fields.get(Wire.NAME), "workspace name"),
            integer(fields, "index"),
            Wire.bool(fields.get(Wire.FOCUSED), "workspace focused"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                Wire.NAME,
                "index",
                Wire.FOCUSED
            )
        );
    }

    static Snapshots.ScreenSnapshot decodeScreen(Object value) {
        Map<String, Object> fields = Wire.object(value, "screen snapshot");
        return new Snapshots.ScreenSnapshot(
            new Ids.ScreenId(Wire.string(fields.get("id"), "screen id")),
            requiredExactId(fields, "workspace_id", Ids.WorkspaceId::new),
            requiredNullableString(fields, Wire.NAME),
            integer(fields, "index"),
            Wire.bool(fields.get(Wire.FOCUSED), "screen focused"),
            Map.copyOf(Wire.object(fields.get(Wire.LAYOUT), "screen layout")),
            snapshotExtra(
                fields,
                "id",
                "workspace_id",
                Wire.NAME,
                "index",
                Wire.FOCUSED,
                Wire.LAYOUT
            )
        );
    }

    static Snapshots.PaneSnapshot decodePane(Object value) {
        Map<String, Object> fields = Wire.object(value, "pane snapshot");
        return new Snapshots.PaneSnapshot(
            new Ids.PaneId(Wire.string(fields.get("id"), "pane id")),
            requiredExactId(fields, "screen_id", Ids.ScreenId::new),
            requiredNullableString(fields, Wire.NAME),
            Wire.bool(fields.get(Wire.FOCUSED), "pane focused"),
            Wire.bool(fields.get("zoomed"), "pane zoomed"),
            snapshotExtra(
                fields,
                "id",
                "screen_id",
                Wire.NAME,
                Wire.FOCUSED,
                "zoomed"
            )
        );
    }

    static Snapshots.TabSnapshot decodeTab(Object value) {
        Map<String, Object> fields = Wire.object(value, "tab snapshot");
        String kind = Wire.string(fields.get("content_kind"), "tab content kind");
        String content = Wire.string(fields.get("content_id"), "tab content id");
        Ids.Id contentId = switch (kind) {
            case "terminal" -> new Ids.TerminalId(content);
            case "browser" -> new Ids.BrowserId(content);
            default -> throw new IllegalArgumentException(
                "tab content kind must be terminal or browser"
            );
        };
        return new Snapshots.TabSnapshot(
            new Ids.TabId(Wire.string(fields.get("id"), "tab id")),
            requiredExactId(fields, "pane_id", Ids.PaneId::new),
            requiredNullableString(fields, Wire.NAME),
            integer(fields, "index"),
            Wire.bool(fields.get(Wire.FOCUSED), "tab focused"),
            kind,
            contentId,
            snapshotExtra(
                fields,
                "id",
                "pane_id",
                Wire.NAME,
                "content_kind",
                "content_id",
                "index",
                Wire.FOCUSED
            )
        );
    }

    static Snapshots.TerminalSnapshot decodeTerminal(Object value) {
        Map<String, Object> fields = Wire.object(value, "terminal snapshot");
        return new Snapshots.TerminalSnapshot(
            new Ids.TerminalId(Wire.string(fields.get("id"), "terminal id")),
            requiredExactId(fields, "tab_id", Ids.TabId::new),
            Wire.string(fields.get(Wire.TITLE), "terminal title"),
            optionalString(fields, Wire.CWD),
            integer(fields, Wire.COLS),
            integer(fields, Wire.ROWS),
            Wire.bool(fields.get("running"), "terminal running"),
            snapshotExtra(
                fields,
                "id",
                "tab_id",
                Wire.TITLE,
                Wire.CWD,
                Wire.COLS,
                Wire.ROWS,
                "running"
            )
        );
    }

    static Snapshots.BrowserSnapshot decodeBrowser(Object value) {
        Map<String, Object> fields = Wire.object(value, "browser snapshot");
        Map<String, Object> size = Wire.object(fields.get("size"), "browser size");
        requireExactFields(size, "browser size", Wire.COLS, Wire.ROWS);
        return new Snapshots.BrowserSnapshot(
            new Ids.BrowserId(Wire.string(fields.get("id"), "browser id")),
            requiredExactId(fields, "tab_id", Ids.TabId::new),
            Wire.string(fields.get(Wire.URL), "browser url"),
            Wire.string(fields.get(Wire.TITLE), "browser title"),
            Wire.bool(fields.get("loading"), "browser loading"),
            Wire.string(fields.get("source"), "browser source"),
            Wire.string(fields.get("status"), "browser status"),
            requiredNullableString(fields, "error"),
            Wire.bool(fields.get("frames_stalled"), "browser frames stalled"),
            new Snapshots.Size(integer(size, Wire.COLS), integer(size, Wire.ROWS)),
            snapshotExtra(
                fields,
                "id",
                "tab_id",
                Wire.URL,
                Wire.TITLE,
                "loading",
                "source",
                "status",
                "error",
                "frames_stalled",
                "size"
            )
        );
    }

    static Snapshots.ConnectedClientSnapshot decodeConnectedClient(Object value) {
        Map<String, Object> fields = Wire.object(value, "client snapshot");
        List<Ids.TerminalId> attachedTerminalIds = Wire.array(
            fields.get("attached_terminal_ids"),
            "client attached_terminal_ids"
        ).stream().map(item -> new Ids.TerminalId(
            Wire.string(item, "client attached terminal id")
        )).toList();
        List<Snapshots.ClientTerminalSize> sizes = Wire.array(
            fields.get("sizes"),
            "client sizes"
        ).stream().map(Client::decodeClientTerminalSize).toList();
        return new Snapshots.ConnectedClientSnapshot(
            new Ids.ConnectedClientId(Wire.string(fields.get("id"), "client id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            requiredNullableString(fields, Wire.NAME),
            requiredNullableString(fields, "client_kind"),
            Wire.string(fields.get("transport"), "client transport"),
            Wire.decimal(
                fields.get("connected_seconds"),
                "client connected_seconds"
            ),
            attachedTerminalIds,
            sizes,
            Wire.bool(fields.get("self"), "client self"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                Wire.NAME,
                "client_kind",
                "transport",
                "connected_seconds",
                "attached_terminal_ids",
                "sizes",
                "self"
            )
        );
    }

    private static Snapshots.ClientTerminalSize decodeClientTerminalSize(
        Object value
    ) {
        Map<String, Object> fields = Wire.object(value, "client terminal size");
        requireExactFields(
            fields,
            "client terminal size",
            "terminal_id",
            Wire.COLS,
            Wire.ROWS,
            "participating"
        );
        return new Snapshots.ClientTerminalSize(
            requiredExactId(fields, "terminal_id", Ids.TerminalId::new),
            requiredNullableInteger(fields, Wire.COLS),
            requiredNullableInteger(fields, Wire.ROWS),
            Wire.bool(fields.get("participating"), "client size participating")
        );
    }

    static Snapshots.NotificationSnapshot decodeNotification(Object value) {
        Map<String, Object> fields = Wire.object(value, "notification snapshot");
        return new Snapshots.NotificationSnapshot(
            new Ids.NotificationId(
                Wire.string(fields.get("id"), "notification id")
            ),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            Wire.string(fields.get(Wire.TITLE), "notification title"),
            Wire.string(fields.get(Wire.BODY), "notification body"),
            Wire.string(fields.get(Wire.LEVEL), "notification level"),
            optionalExactId(fields, "terminal_id", Ids.TerminalId::new),
            Wire.decimal(
                fields.get("created_at_ms"),
                "notification created_at_ms"
            ),
            Wire.bool(fields.get("unread"), "notification unread"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                Wire.TITLE,
                Wire.BODY,
                Wire.LEVEL,
                "terminal_id",
                "created_at_ms",
                "unread"
            )
        );
    }

    static Snapshots.AgentSnapshot decodeAgent(Object value) {
        Map<String, Object> fields = Wire.object(value, "agent snapshot");
        return new Snapshots.AgentSnapshot(
            new Ids.AgentId(Wire.string(fields.get("id"), "agent id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            requiredExactId(fields, "terminal_id", Ids.TerminalId::new),
            Wire.string(fields.get(Wire.STATE), "agent state"),
            Wire.string(fields.get("source"), "agent source"),
            Wire.decimal(fields.get("updated_at_ms"), "agent updated_at_ms"),
            requiredNullableString(fields, "source_session"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                "terminal_id",
                Wire.STATE,
                "source",
                "updated_at_ms",
                "source_session"
            )
        );
    }

    static Snapshots.PairingRequestSnapshot decodePairingRequest(Object value) {
        Map<String, Object> fields = Wire.object(value, "pairing request snapshot");
        return new Snapshots.PairingRequestSnapshot(
            new Ids.PairingRequestId(
                Wire.string(fields.get("id"), "pairing request id")
            ),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            Wire.string(fields.get("peer"), "pairing request peer"),
            new Secret(Wire.string(fields.get("code"), "pairing request code")),
            Wire.decimal(
                fields.get("expires_in_seconds"),
                "pairing request expires_in_seconds"
            ),
            Wire.string(fields.get("status"), "pairing request status"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                "peer",
                "code",
                "expires_in_seconds",
                "status"
            )
        );
    }

    static Snapshots.FrontendProjectionSnapshot decodeFrontendProjection(
        Object value
    ) {
        Map<String, Object> fields = Wire.object(value, "frontend projection snapshot");
        Object rawProjection = fields.containsKey("projection")
            ? fields.get("projection")
            : fields.get(Wire.VALUE);
        Map<String, Object> projection = rawProjection instanceof Map<?, ?>
            ? Wire.object(rawProjection, "frontend projection")
            : Map.of(Wire.VALUE, rawProjection);
        return new Snapshots.FrontendProjectionSnapshot(
            new Ids.ProjectionId(Wire.string(fields.get("id"), "projection id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            projection,
            snapshotExtra(
                fields,
                "id",
                "session_id",
                "projection",
                Wire.VALUE
            )
        );
    }

    static Snapshots.SidebarViewSnapshot decodeSidebarView(Object value) {
        Map<String, Object> fields = Wire.object(value, "sidebar view snapshot");
        return new Snapshots.SidebarViewSnapshot(
            new Ids.SidebarViewId(Wire.string(fields.get("id"), "sidebar view id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            integer(fields, Wire.COLS),
            integer(fields, Wire.ROWS),
            Wire.bool(fields.get("running"), "sidebar view running"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                Wire.COLS,
                Wire.ROWS,
                "running"
            )
        );
    }

    static Snapshots.ProviderScopeSnapshot decodeProviderScope(Object value) {
        Map<String, Object> fields = Wire.object(value, "provider scope snapshot");
        return new Snapshots.ProviderScopeSnapshot(
            new Ids.ProviderScopeId(
                Wire.string(fields.get("id"), "provider scope id")
            ),
            Wire.string(fields.get(Wire.NAME), "provider scope name"),
            Wire.string(fields.get(Wire.KIND), "provider scope kind"),
            Wire.bool(fields.get("can_admin"), "provider scope can_admin"),
            Wire.bool(fields.get("selected"), "provider scope selected"),
            snapshotExtra(
                fields,
                "id",
                Wire.NAME,
                Wire.KIND,
                "can_admin",
                "selected"
            )
        );
    }

    static Snapshots.ProviderActionSnapshot decodeProviderAction(Object value) {
        Map<String, Object> fields = Wire.object(value, "provider action snapshot");
        return new Snapshots.ProviderActionSnapshot(
            new Ids.ProviderActionId(
                Wire.string(fields.get("id"), "provider action id")
            ),
            requiredExactId(
                fields,
                "provider_scope_id",
                Ids.ProviderScopeId::new
            ),
            Wire.string(fields.get(Wire.NAME), "provider action name"),
            Wire.string(fields.get(Wire.TITLE), "provider action title"),
            Wire.bool(fields.get(Wire.ENABLED), "provider action enabled"),
            Wire.string(fields.get("target"), "provider action target"),
            Wire.bool(fields.get("destructive"), "provider action destructive"),
            Wire.array(fields.get("fields"), "provider action fields").stream()
                .map(Client::decodeProviderActionField)
                .toList(),
            snapshotExtra(
                fields,
                "id",
                "provider_scope_id",
                Wire.NAME,
                Wire.TITLE,
                Wire.ENABLED,
                "target",
                "destructive",
                "fields"
            )
        );
    }

    private static Snapshots.ProviderActionField decodeProviderActionField(
        Object value
    ) {
        Map<String, Object> fields = Wire.object(value, "provider action field");
        requireExactFields(
            fields,
            "provider action field",
            "id",
            Wire.LABEL,
            Wire.KIND,
            "required",
            "max_length",
            "minimum",
            "maximum",
            "placeholder"
        );
        return new Snapshots.ProviderActionField(
            Wire.string(fields.get("id"), "provider action field id"),
            Wire.string(fields.get(Wire.LABEL), "provider action field label"),
            Wire.string(fields.get(Wire.KIND), "provider action field kind"),
            Wire.bool(fields.get("required"), "provider action field required"),
            optionalInteger(fields, "max_length"),
            optionalInteger(fields, "minimum"),
            optionalInteger(fields, "maximum"),
            optionalString(fields, "placeholder")
        );
    }

    static Snapshots.ProviderNoticeSnapshot decodeProviderNotice(Object value) {
        Map<String, Object> fields = Wire.object(value, "provider notice snapshot");
        return new Snapshots.ProviderNoticeSnapshot(
            new Ids.ProviderNoticeId(
                Wire.string(fields.get("id"), "provider notice id")
            ),
            requiredExactId(
                fields,
                "provider_scope_id",
                Ids.ProviderScopeId::new
            ),
            Wire.string(fields.get(Wire.LEVEL), "provider notice level"),
            Wire.string(fields.get("message"), "provider notice message"),
            snapshotExtra(
                fields,
                "id",
                "provider_scope_id",
                Wire.LEVEL,
                "message"
            )
        );
    }

    static Optional<String> optionalString(Map<String, Object> fields, String key) {
        Object value = fields.get(key);
        return value == null ? Optional.empty() : Optional.of(Wire.string(value, key));
    }

    static Optional<String> requiredNullableString(
        Map<String, Object> fields,
        String key
    ) {
        if (!fields.containsKey(key)) {
            throw new ProtocolError(key + " is required, although it may be null");
        }
        return optionalString(fields, key);
    }

    static Optional<Decimal> optionalDecimal(Map<String, Object> fields) {
        return fields.get(Wire.REVISION) == null
            ? Optional.empty()
            : Optional.of(Wire.decimal(fields.get(Wire.REVISION), Wire.REVISION));
    }

    static int integer(Map<String, Object> fields, String key) {
        Object value = fields.get(key);
        if (!(value instanceof Number number)) {
            throw new IllegalArgumentException(key + " must be an integer");
        }
        try {
            return new java.math.BigDecimal(number.toString()).intValueExact();
        } catch (ArithmeticException error) {
            throw new IllegalArgumentException(key + " must fit a signed 32-bit integer", error);
        }
    }

    static Optional<Integer> optionalInteger(
        Map<String, Object> fields,
        String key
    ) {
        return fields.containsKey(key) && fields.get(key) != null
            ? Optional.of(integer(fields, key))
            : Optional.empty();
    }

    static Optional<Integer> requiredNullableInteger(
        Map<String, Object> fields,
        String key
    ) {
        if (!fields.containsKey(key)) {
            throw new ProtocolError(key + " is required, although it may be null");
        }
        return optionalInteger(fields, key);
    }

    static Map<String, Object> optionalObject(
        Map<String, Object> fields,
        String key
    ) {
        Object value = fields.get(key);
        return value == null ? Map.of() : Wire.object(value, key);
    }

    static List<Object> optionalArray(Map<String, Object> fields, String key) {
        Object value = fields.get(key);
        return value == null ? List.of() : Wire.array(value, key);
    }

    static Map<String, Object> extra(Map<String, Object> fields, String... known) {
        Map<String, Object> result = copy(fields);
        result.keySet().removeAll(List.of(known));
        return Map.copyOf(result);
    }

    static Map<String, Object> snapshotExtra(
        Map<String, Object> fields,
        String... known
    ) {
        Map<String, Object> result = copy(fields);
        result.keySet().removeAll(List.of(known));
        boolean hasExplicitExtra = result.containsKey("extra");
        Object explicit = result.remove("extra");
        if (!result.isEmpty()) {
            throw new ProtocolError(
                "snapshot has unknown fields " + result.keySet()
            );
        }
        if (!hasExplicitExtra) {
            return Map.of();
        }
        return Map.copyOf(Wire.object(explicit, "snapshot extra"));
    }

    static void requireExactFields(
        Map<String, Object> fields,
        String context,
        String... allowed
    ) {
        for (String key : fields.keySet()) {
            if (!List.of(allowed).contains(key)) {
                throw new ProtocolError(
                    context + " has unknown field " + key
                );
            }
        }
    }

    private static <T> Optional<T> optionalId(
        Map<String, Object> fields,
        String key,
        java.util.function.Function<String, T> constructor
    ) {
        Object value = fields.get(key);
        if (value == null) {
            value = fields.get(key + "_id");
        }
        return value == null
            ? Optional.empty()
            : Optional.of(constructor.apply(Wire.string(value, key)));
    }

    private static <T> T requiredId(
        Map<String, Object> fields,
        String key,
        java.util.function.Function<String, T> constructor
    ) {
        return optionalId(fields, key, constructor).orElseThrow(
            () -> new IllegalArgumentException(key + " id is required")
        );
    }

    private static <T> Optional<T> optionalExactId(
        Map<String, Object> fields,
        String key,
        java.util.function.Function<String, T> constructor
    ) {
        Object value = fields.get(key);
        return value == null
            ? Optional.empty()
            : Optional.of(constructor.apply(Wire.string(value, key)));
    }

    private static <T> T requiredExactId(
        Map<String, Object> fields,
        String key,
        java.util.function.Function<String, T> constructor
    ) {
        return optionalExactId(fields, key, constructor).orElseThrow(
            () -> new ProtocolError(key + " is required")
        );
    }

    private static Duration positive(Duration value, String name) {
        Objects.requireNonNull(value, name);
        if (value.isNegative() || value.isZero()) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return value;
    }

    private static RuntimeException transportError(String message, Throwable error) {
        return error instanceof RuntimeException runtime
            ? runtime
            : new TransportError(message, error);
    }

    private static Supplier<String> randomSource(String prefix) {
        SecureRandom random = new SecureRandom();
        return () -> {
            byte[] entropy = new byte[16];
            random.nextBytes(entropy);
            StringBuilder result = new StringBuilder(prefix);
            for (byte value : entropy) {
                result.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
            }
            return result.toString();
        };
    }

    public static final class Builder {
        private Path socket;
        private String session = "main";
        private Duration timeout = Duration.ofSeconds(10);
        private int maxRequestBytes = MAX_REQUEST_BYTES;
        private int maxResponseBytes = MAX_RESPONSE_BYTES;
        private Transport transport;
        private Supplier<String> idempotencyKeys;
        private Supplier<String> streamIds;

        private Builder() {}

        public Builder socket(Path value) { socket = value; return this; }
        public Builder session(String value) { session = Objects.requireNonNull(value, "value"); return this; }
        public Builder timeout(Duration value) { timeout = value; return this; }
        public Builder maxRequestBytes(int value) { maxRequestBytes = value; return this; }
        public Builder maxResponseBytes(int value) { maxResponseBytes = value; return this; }
        public Builder transport(Transport value) { transport = Objects.requireNonNull(value, "value"); return this; }
        public Builder idempotencyKeySource(Supplier<String> value) { idempotencyKeys = Objects.requireNonNull(value, "value"); return this; }
        public Builder streamIdSource(Supplier<String> value) { streamIds = Objects.requireNonNull(value, "value"); return this; }
        public Client build() { return new Client(this); }
    }
}
