package com.cmux.raw;

import com.cmux.raw.Authority;
import com.cmux.raw.BrowserAttachEvent;
import com.cmux.raw.ByteAttachEvent;
import com.cmux.raw.CommandMetadata;
import com.cmux.raw.Commands;
import com.cmux.raw.CreateWorkspaceRequest;
import com.cmux.raw.DeltaStreamEvent;
import com.cmux.raw.GeneratedCmuxClient;
import com.cmux.raw.ProtocolEvent;
import com.cmux.raw.ReadScrollbackRequest;
import com.cmux.raw.ReadScrollbackResult;
import com.cmux.raw.RenderAttachEvent;
import com.cmux.raw.StreamKind;
import com.cmux.raw.SubscribeEvent;
import com.cmux.raw.WorkspaceMutationResult;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Collections;
import java.util.EnumSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Dependency-free Java 17 client for the cmux-tui protocol.
 *
 * <p>Generated typed commands are inherited from {@link GeneratedCmuxClient}.
 * Each event stream owns a dedicated socket so closing it cancels that stream
 * without interfering with command calls.
 */
public final class CmuxClient extends GeneratedCmuxClient implements AutoCloseable {
    public static final int DEFAULT_MAX_BUFFERED_STREAM_EVENTS = 1_024;
    public static final int MAX_SCROLLBACK_PAGE_ROWS = 65_535;

    private final Path socketPath;
    private final Duration timeout;
    private final int maxRequestBytes;
    private final int maxResponseBytes;
    private final int maxJsonDepth;
    private final int maxBufferedStreamEvents;
    private final Set<Authority> authorities;
    private final JsonLineConnection connection;
    private final AtomicLong nextId = new AtomicLong(1);
    private final AtomicBoolean closed = new AtomicBoolean();
    private final Object commandLock = new Object();
    private volatile Integer protocol;
    private volatile Set<String> capabilities = Set.of();

    private CmuxClient(Builder builder) throws CmuxException {
        this.socketPath = SocketDiscovery.resolve(builder.socketPath, builder.session);
        this.timeout = positive(builder.timeout, "timeout");
        this.maxRequestBytes = positive(builder.maxRequestBytes, "maxRequestBytes");
        this.maxResponseBytes = positive(builder.maxResponseBytes, "maxResponseBytes");
        this.maxJsonDepth = positive(builder.maxJsonDepth, "maxJsonDepth");
        this.maxBufferedStreamEvents = positive(
            builder.maxBufferedStreamEvents,
            "maxBufferedStreamEvents"
        );
        this.authorities = Collections.unmodifiableSet(EnumSet.copyOf(builder.authorities));
        this.connection = connect();
    }

    public static Builder builder() {
        return new Builder();
    }

    public static String defaultSocketPath(String session) {
        return SocketDiscovery.defaultSocketPath(session).toString();
    }

    public static String resolvedSocketPath(String session) {
        return SocketDiscovery.resolve(null, session).toString();
    }

    public Path socketPath() {
        return socketPath;
    }

    public Duration timeout() {
        return timeout;
    }

    public Set<Authority> authorities() {
        return authorities;
    }

    public Integer negotiatedProtocol() {
        return protocol;
    }

    public Set<String> capabilities() {
        return capabilities;
    }

    /**
     * Reads up to {@code count} rows from the current end of retained scrollback.
     *
     * <p>This best-effort helper first sends a zero-count probe to learn the
     * current total, then requests one page ending at that total when
     * {@code count} is nonzero. Scrollback eviction or resize reflow between
     * those two snapshots can shift the returned range. One protocol page is limited to
     * {@value #MAX_SCROLLBACK_PAGE_ROWS} rows.
     */
    public ReadScrollbackResult readScrollbackTail(UInt64 surface, int count)
        throws CmuxException {
        Objects.requireNonNull(surface, "surface");
        if (count < 0 || count > MAX_SCROLLBACK_PAGE_ROWS) {
            throw new IllegalArgumentException(
                "count must be between 0 and " + MAX_SCROLLBACK_PAGE_ROWS
            );
        }
        ReadScrollbackResult probe = readScrollback(
            ReadScrollbackRequest.builder()
                .surface(surface)
                .start(0)
                .count(0)
                .build()
        );
        if (count == 0) {
            return probe;
        }
        long start = Math.max(0L, probe.total() - count);
        return readScrollback(
            ReadScrollbackRequest.builder()
                .surface(surface)
                .start(start)
                .count(count)
                .build()
        );
    }

    /** Creates a workspace and returns an idempotently closeable owner for it. */
    public WorkspaceLease createWorkspaceLease(CreateWorkspaceRequest request)
        throws CmuxException {
        WorkspaceMutationResult creation = createWorkspace(
            Objects.requireNonNull(request, "request")
        );
        return new WorkspaceLease(this, creation);
    }

    /** Creates an unnamed workspace and returns an idempotently closeable owner for it. */
    public WorkspaceLease createWorkspaceLease() throws CmuxException {
        return createWorkspaceLease(CreateWorkspaceRequest.builder().build());
    }

    /**
     * Sends a complete request envelope. The client adds an id when absent and
     * returns the complete response envelope without decoding command data.
     */
    public Map<String, Object> rawRequest(Map<String, Object> request) throws CmuxException {
        return rawRequest(request, () -> {});
    }

    Map<String, Object> rawRequest(Map<String, Object> request, Runnable beforeWait)
        throws CmuxException {
        Objects.requireNonNull(request, "request");
        Objects.requireNonNull(beforeWait, "beforeWait");
        synchronized (commandLock) {
            ensureOpen();
            LinkedHashMap<String, Object> payload = new LinkedHashMap<>(request);
            if (!(payload.get("cmd") instanceof String)) {
                throw new IllegalArgumentException("raw request requires string cmd");
            }
            payload.putIfAbsent("id", nextRequestId());
            Object id = payload.get("id");
            JsonLineConnection.Deadline deadline = JsonLineConnection.deadline(timeout);
            connection.send(payload, deadline);
            while (true) {
                Map<String, Object> response = connection.receive(deadline, beforeWait);
                if (response.containsKey("event")) {
                    continue;
                }
                if (!response.containsKey("id") || idsEqual(response.get("id"), id)) {
                    return response;
                }
            }
        }
    }

    @Override
    protected Object execute(
        CommandMetadata metadata,
        Map<String, Object> params
    ) throws CmuxException {
        if (metadata.streamKind() != StreamKind.NONE) {
            throw new IllegalArgumentException(metadata.wireName() + " is a stream command");
        }
        checkAuthority(metadata);
        checkVersion(metadata, params);
        LinkedHashMap<String, Object> request = new LinkedHashMap<>(params);
        request.put("cmd", metadata.wireName());
        Map<String, Object> response = rawRequest(request);
        if (!Boolean.TRUE.equals(response.get("ok"))) {
            throw commandError(response);
        }
        Object data = response.get("data");
        if ("identify".equals(metadata.wireName()) || "ping".equals(metadata.wireName())) {
            recordNegotiation(data);
        }
        return data;
    }

    @Override
    protected CmuxStream<ProtocolEvent> openStream(
        CommandMetadata metadata,
        Map<String, Object> params
    ) throws CmuxException {
        return openTypedStream(metadata, params, ProtocolEvent.class);
    }

    /** Coarse subscription with typed events and unknown-event fallback. */
    public CmuxStream<SubscribeEvent> subscribeEvents() throws CmuxException {
        return subscribeEvents(false);
    }

    /** Lifecycle-delta subscription, including tree-changed resync events. */
    public CmuxStream<DeltaStreamEvent> subscribeDeltas() throws CmuxException {
        LinkedHashMap<String, Object> params = new LinkedHashMap<>();
        params.put("tree_events", "deltas");
        return openTypedStream(Commands.SUBSCRIBE, params, DeltaStreamEvent.class);
    }

    public CmuxStream<SubscribeEvent> subscribeEvents(boolean deltas) throws CmuxException {
        LinkedHashMap<String, Object> params = new LinkedHashMap<>();
        if (deltas) {
            params.put("tree_events", "deltas");
        }
        Class<? extends SubscribeEvent> type = deltas
            ? DeltaStreamEvent.class
            : SubscribeEvent.class;
        @SuppressWarnings({"rawtypes", "unchecked"})
        CmuxStream<SubscribeEvent> stream = (CmuxStream) openTypedStream(
            Commands.SUBSCRIBE,
            params,
            type
        );
        return stream;
    }

    public CmuxStream<ByteAttachEvent> attachBytes(UInt64 surface) throws CmuxException {
        return attachBytes(surface, null, null);
    }

    public CmuxStream<ByteAttachEvent> attachBytes(
        UInt64 surface,
        Integer cols,
        Integer rows
    ) throws CmuxException {
        return attach(surface, null, cols, rows, ByteAttachEvent.class);
    }

    public CmuxStream<RenderAttachEvent> attachRender(UInt64 surface) throws CmuxException {
        return attach(surface, "render", null, null, RenderAttachEvent.class);
    }

    public CmuxStream<BrowserAttachEvent> attachBrowser(UInt64 surface) throws CmuxException {
        return attach(surface, null, null, null, BrowserAttachEvent.class);
    }

    private <E extends ProtocolEvent> CmuxStream<E> attach(
        UInt64 surface,
        String mode,
        Integer cols,
        Integer rows,
        Class<E> eventType
    ) throws CmuxException {
        Objects.requireNonNull(surface, "surface");
        if ((cols == null) != (rows == null)) {
            throw new IllegalArgumentException("attach cols and rows must be supplied together");
        }
        LinkedHashMap<String, Object> params = new LinkedHashMap<>();
        params.put("surface", surface);
        if (mode != null) {
            params.put("mode", mode);
        }
        if (cols != null) {
            params.put("cols", cols);
            params.put("rows", rows);
        }
        return openTypedStream(Commands.ATTACH_SURFACE, params, eventType);
    }

    private <E extends ProtocolEvent> CmuxStream<E> openTypedStream(
        CommandMetadata metadata,
        Map<String, Object> params,
        Class<E> eventType
    ) throws CmuxException {
        if (metadata.streamKind() == StreamKind.NONE) {
            throw new IllegalArgumentException(metadata.wireName() + " is not a stream command");
        }
        checkAuthority(metadata);
        checkVersion(metadata, params);
        LinkedHashMap<String, Object> request = new LinkedHashMap<>(params);
        request.put("id", nextRequestId());
        request.put("cmd", metadata.wireName());
        JsonLineConnection streamConnection = connect();
        return CmuxStream.open(
            streamConnection,
            timeout,
            request,
            eventType,
            maxBufferedStreamEvents
        );
    }

    private void checkAuthority(CommandMetadata metadata) throws CmuxAuthorityException {
        if (!authorities.contains(metadata.authority())) {
            throw new CmuxAuthorityException(
                metadata.wireName() + " requires " + metadata.authority().wireValue()
            );
        }
    }

    private void checkVersion(
        CommandMetadata metadata,
        Map<String, Object> params
    ) throws CmuxException {
        if ("identify".equals(metadata.wireName()) || "ping".equals(metadata.wireName())) {
            return;
        }
        ensureNegotiated();
        if (protocol < metadata.since()) {
            throw new CmuxProtocolMismatchException(
                metadata.wireName() + " requires protocol " + metadata.since()
                    + "; server uses protocol " + protocol
            );
        }
        if (metadata.capability() != null && !capabilities.contains(metadata.capability())) {
            throw new CmuxProtocolMismatchException(
                metadata.wireName() + " requires capability " + metadata.capability()
            );
        }
        for (Map.Entry<String, Long> field : metadata.fieldSince().entrySet()) {
            if (params.get(field.getKey()) != null && protocol < field.getValue()) {
                throw new CmuxProtocolMismatchException(
                    metadata.wireName() + "." + field.getKey()
                        + " requires protocol " + field.getValue()
                        + "; server uses protocol " + protocol
                );
            }
        }
        for (Map.Entry<String, String> field : metadata.fieldCapabilities().entrySet()) {
            if (params.get(field.getKey()) != null && !capabilities.contains(field.getValue())) {
                throw new CmuxProtocolMismatchException(
                    metadata.wireName() + "." + field.getKey()
                        + " requires capability " + field.getValue()
                );
            }
        }
        if ("attach-surface".equals(metadata.wireName())
                && ((params.get("cols") != null) != (params.get("rows") != null))) {
            throw new IllegalArgumentException(
                "attach-surface cols and rows must be supplied together"
            );
        }
        if ("attach-surface".equals(metadata.wireName())
                && (params.get("cols") != null || params.get("rows") != null)
                && !capabilities.contains("attach-initial-size")) {
            throw new CmuxProtocolMismatchException(
                "initial attach sizing requires capability attach-initial-size"
            );
        }
    }

    private void ensureNegotiated() throws CmuxException {
        if (protocol != null) {
            return;
        }
        LinkedHashMap<String, Object> request = new LinkedHashMap<>();
        request.put("cmd", "identify");
        Map<String, Object> response = rawRequest(request);
        if (!Boolean.TRUE.equals(response.get("ok"))) {
            throw commandError(response);
        }
        recordNegotiation(response.get("data"));
    }

    private void recordNegotiation(Object value) {
        Map<String, Object> data = Wire.object(value, "identify result");
        this.protocol = Wire.int32(Wire.required(data, "protocol"), "identify.protocol");
        Object rawCapabilities = Wire.optional(data, "capabilities");
        if (Wire.isMissing(rawCapabilities) || rawCapabilities == null) {
            this.capabilities = Set.of();
        } else {
            this.capabilities = Set.copyOf(
                Wire.array(rawCapabilities, "identify.capabilities", item ->
                    Wire.string(item, "identify.capabilities item")
                )
            );
        }
    }

    private CmuxCommandException commandError(Map<String, Object> response) {
        return new CmuxCommandException(
            String.valueOf(response.getOrDefault("error", "unknown error")),
            response.get("id")
        );
    }

    private JsonLineConnection connect() throws CmuxTransportException {
        return JsonLineConnection.connect(
            socketPath,
            maxRequestBytes,
            maxResponseBytes,
            maxJsonDepth
        );
    }

    private String nextRequestId() {
        long value = nextId.getAndIncrement();
        if (value <= 0) {
            throw new IllegalStateException("request id space exhausted");
        }
        return "java-" + value;
    }

    static boolean idsEqual(Object left, Object right) {
        if (left == null || right == null) {
            return left == right;
        }
        if (left instanceof Number && right instanceof Number) {
            try {
                return new BigDecimal(left.toString()).compareTo(new BigDecimal(right.toString())) == 0;
            } catch (NumberFormatException ignored) {
                return false;
            }
        }
        return left.equals(right);
    }

    private void ensureOpen() throws CmuxTransportException {
        if (closed.get()) {
            throw new CmuxTransportException("client is closed");
        }
    }

    @Override
    public void close() {
        if (closed.compareAndSet(false, true)) {
            connection.close();
        }
    }

    private static Duration positive(Duration value, String name) {
        Objects.requireNonNull(value, name);
        if (value.isNegative() || value.isZero()) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return value;
    }

    private static int positive(int value, String name) {
        if (value < 1) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return value;
    }

    public static final class Builder {
        private Path socketPath;
        private String session = "main";
        private Duration timeout = Duration.ofSeconds(10);
        private int maxRequestBytes = JsonLineConnection.DEFAULT_MAX_REQUEST_BYTES;
        private int maxResponseBytes = JsonLineConnection.DEFAULT_MAX_RESPONSE_BYTES;
        private int maxJsonDepth = Json.DEFAULT_MAX_DEPTH;
        private int maxBufferedStreamEvents = DEFAULT_MAX_BUFFERED_STREAM_EVENTS;
        private final EnumSet<Authority> authorities = EnumSet.of(
            Authority.CONTROL,
            Authority.FRONTEND,
            Authority.LOCAL_ADMIN
        );

        public Builder socketPath(String socketPath) {
            this.socketPath = Path.of(socketPath);
            return this;
        }

        public Builder socketPath(Path socketPath) {
            this.socketPath = Objects.requireNonNull(socketPath, "socketPath");
            return this;
        }

        public Builder session(String session) {
            SocketDiscovery.validateSession(session);
            this.session = session;
            return this;
        }

        public Builder timeout(Duration timeout) {
            this.timeout = positive(timeout, "timeout");
            return this;
        }

        public Builder maxRequestBytes(int maxRequestBytes) {
            this.maxRequestBytes = positive(maxRequestBytes, "maxRequestBytes");
            return this;
        }

        public Builder maxResponseBytes(int maxResponseBytes) {
            this.maxResponseBytes = positive(maxResponseBytes, "maxResponseBytes");
            return this;
        }

        public Builder maxJsonDepth(int maxJsonDepth) {
            this.maxJsonDepth = positive(maxJsonDepth, "maxJsonDepth");
            return this;
        }

        public Builder maxBufferedStreamEvents(int maxBufferedStreamEvents) {
            this.maxBufferedStreamEvents = positive(
                maxBufferedStreamEvents,
                "maxBufferedStreamEvents"
            );
            return this;
        }

        public Builder authorities(Authority... values) {
            authorities.clear();
            for (Authority value : values) {
                authorities.add(Objects.requireNonNull(value, "authority"));
            }
            return this;
        }

        public Builder enableProviderAuthority() {
            authorities.add(Authority.PROVIDER_AUTHORITY);
            return this;
        }

        public CmuxClient build() throws CmuxException {
            return new CmuxClient(this);
        }
    }
}
