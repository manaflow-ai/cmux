package com.cmux;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayDeque;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

public final class CmuxClient implements AutoCloseable {
    private final String socketPath;
    private final Duration timeout;
    private final boolean allowProtocolV6Attach;
    private final JsonLineConnection connection;
    private long nextId = 1;
    private Integer protocol;
    private IdentifyResult identity;

    private CmuxClient(Builder builder) throws CmuxException {
        this.socketPath = builder.socketPath != null ? builder.socketPath : resolvedSocketPath(builder.session);
        this.timeout = builder.timeout;
        this.allowProtocolV6Attach = builder.allowProtocolV6Attach;
        this.connection = JsonLineConnection.connect(socketPath);
    }

    public static Builder builder() {
        return new Builder();
    }

    public static String defaultSocketPath(String session) {
        String base = runtimeBase(System.getenv("XDG_RUNTIME_DIR"), System.getenv("TMPDIR"));
        return defaultSocketPathFrom(base, currentUid(), session, isDarwin());
    }

    static String runtimeBase(String xdgRuntimeDir, String tmpDir) {
        if (xdgRuntimeDir != null && !xdgRuntimeDir.isEmpty()) {
            return xdgRuntimeDir;
        }
        if (tmpDir != null && !tmpDir.isEmpty()) {
            return tmpDir;
        }
        return "/tmp";
    }

    static String defaultSocketPathFrom(String base, String uid, String session, boolean darwin) {
        String candidate = Path.of(base, "cmux-tui-" + uid, session + ".sock").toString();
        if (darwin && candidate.getBytes(StandardCharsets.UTF_8).length > 103) {
            return Path.of("/tmp", "cmux-tui-" + uid, session + ".sock").toString();
        }
        return candidate;
    }

    private static boolean isDarwin() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("mac");
    }

    public static String envSocketPath() {
        String socket = System.getenv("CMUX_TUI_SOCKET");
        if (socket != null && !socket.isBlank()) {
            return socket;
        }
        socket = System.getenv("CMUX_MUX_SOCKET");
        return socket == null || socket.isBlank() ? null : socket;
    }

    public static String resolvedSocketPath(String session) {
        String socket = envSocketPath();
        return socket != null ? socket : defaultSocketPath(session);
    }

    private static String currentUid() {
        Path probe = null;
        try {
            probe = Files.createTempFile("cmux-tui-uid", ".tmp");
            return String.valueOf(Files.getAttribute(probe, "unix:uid"));
        } catch (IOException | UnsupportedOperationException err) {
            String uid = System.getenv("UID");
            return uid == null || uid.isBlank() ? System.getProperty("user.name", "0") : uid;
        } finally {
            if (probe != null) {
                try {
                    Files.deleteIfExists(probe);
                } catch (IOException ignored) {
                    // best-effort cleanup
                }
            }
        }
    }

    public IdentifyResult identify() throws CmuxException {
        Map<String, Object> data = request("identify", new LinkedHashMap<>());
        IdentifyResult result = IdentifyResult.from(data);
        protocol = result.protocol();
        identity = result;
        return result;
    }

    public PingResult ping() throws CmuxException {
        try {
            return PingResult.from(request("ping", new LinkedHashMap<>()));
        } catch (IllegalArgumentException err) {
            throw new CmuxDecodeException("invalid ping response", err);
        }
    }

    public TopologySnapshot topologySnapshot() throws CmuxException {
        requireTopologyV8();
        try {
            return TopologySnapshot.from(request("topology-snapshot", new LinkedHashMap<>()));
        } catch (IllegalArgumentException err) {
            throw new CmuxDecodeException("invalid topology snapshot", err);
        }
    }

    public TopologySubscribeOutcome subscribeTopology(TopologyCursor cursor) throws CmuxException {
        requireTopologyV8();
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("id", nextId());
        params.put("cmd", "subscribe-topology");
        params.put("daemon_instance_id", cursor.daemonInstanceId().toString());
        params.put("session_id", cursor.sessionId().toString());
        params.put("revision", cursor.revision());
        CmuxStream stream = CmuxStream.open(socketPath, timeout, params);
        try {
            Map<String, Object> data = stream.responseData();
            String status = TopologyWire.string(data.get("status"));
            if ("resnapshot-required".equals(status)) {
                TopologyResnapshotRequired required = TopologyResnapshotRequired.from(data);
                stream.close();
                return required;
            }
            if (!"subscribed".equals(status)) {
                stream.close();
                throw new CmuxDecodeException("invalid subscribe-topology status " + status, null);
            }
            TopologySubscribed info = TopologySubscribed.from(data);
            if (!info.daemonInstanceId().equals(cursor.daemonInstanceId())
                || !info.sessionId().equals(cursor.sessionId())
                || info.fromRevision() != cursor.revision()) {
                stream.close();
                return topologyFenceFailure(cursor, info);
            }
            return new TopologySubscription(info, stream, cursor);
        } catch (IllegalArgumentException err) {
            stream.close();
            throw new CmuxDecodeException("invalid subscribe-topology response", err);
        }
    }

    private IdentifyResult requireTopologyV8() throws CmuxException {
        IdentifyResult current = identity != null ? identity : identify();
        if (!current.supportsTopologyV8()) {
            StringBuilder missing = new StringBuilder();
            for (String capability : IdentifyResult.TOPOLOGY_V8_CAPABILITIES) {
                if (!current.capabilities().contains(capability)) {
                    if (!missing.isEmpty()) missing.append(',');
                    missing.append(capability);
                }
            }
            throw new CmuxProtocolMismatchException(
                "canonical topology requires protocol 8 and capabilities "
                    + String.join(",", IdentifyResult.TOPOLOGY_V8_CAPABILITIES)
                    + "; server protocol=" + current.protocol() + " missing=" + missing
            );
        }
        if (current.topologyCursor().isEmpty()) {
            throw new CmuxProtocolMismatchException(
                "canonical topology identify response omitted its authority cursor"
            );
        }
        return current;
    }

    private static TopologyResnapshotRequired topologyFenceFailure(
        TopologyCursor cursor,
        TopologySubscribed info
    ) {
        TopologyResnapshotReason reason = !info.daemonInstanceId().equals(cursor.daemonInstanceId())
            ? TopologyResnapshotReason.STALE_DAEMON
            : !info.sessionId().equals(cursor.sessionId())
                ? TopologyResnapshotReason.STALE_SESSION
                : TopologyResnapshotReason.HISTORY_GAP;
        return new TopologyResnapshotRequired(
            info.daemonInstanceId(), info.sessionId(), info.currentRevision(), reason
        );
    }

    public Tree listWorkspaces() throws CmuxException {
        return Tree.from(request("list-workspaces", new LinkedHashMap<>()));
    }

    public void send(long surface, String text) throws CmuxException {
        send(surface, text, null);
    }

    public void send(long surface, String text, byte[] bytes) throws CmuxException {
        Map<String, Object> params = surfaceParams(surface);
        if (text != null) {
            params.put("text", text);
        }
        if (bytes != null) {
            params.put("bytes", Base64.getEncoder().encodeToString(bytes));
        }
        request("send", params);
    }

    public void sendBase64(long surface, String text, String base64Bytes) throws CmuxException {
        Map<String, Object> params = surfaceParams(surface);
        if (text != null) {
            params.put("text", text);
        }
        if (base64Bytes != null) {
            params.put("bytes", base64Bytes);
        }
        request("send", params);
    }

    public ReadScreenResult readScreen(long surface) throws CmuxException {
        return new ReadScreenResult(asString(request("read-screen", surfaceParams(surface)).get("text")));
    }

    public ProcessInfoResult processInfo(long surface) throws CmuxException {
        try {
            return ProcessInfoResult.from(request("process-info", surfaceParams(surface)));
        } catch (IllegalArgumentException err) {
            throw new CmuxDecodeException("invalid process-info response", err);
        }
    }

    public EnsureTerminalResult ensureTerminal(EnsureTerminalRequest ensureRequest) throws CmuxException {
        try {
            return EnsureTerminalResult.from(request("ensure-terminal", ensureRequest.toMap()));
        } catch (IllegalArgumentException err) {
            throw new CmuxDecodeException("invalid ensure-terminal response", err);
        }
    }

    public ReparentTerminalResult reparentTerminal(
        java.util.UUID surfaceUuid,
        java.util.UUID workspaceUuid
    ) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("surface_uuid", surfaceUuid.toString());
        params.put("workspace_uuid", workspaceUuid.toString());
        try {
            return ReparentTerminalResult.from(request("reparent-terminal", params));
        } catch (IllegalArgumentException err) {
            throw new CmuxDecodeException("invalid reparent-terminal response", err);
        }
    }

    public VtStateResult vtState(long surface) throws CmuxException {
        Map<String, Object> data = request("vt-state", surfaceParams(surface));
        return new VtStateResult((int) asLong(data.get("cols")), (int) asLong(data.get("rows")), asString(data.get("data")));
    }

    public SurfaceResult newTab(Long pane, String cwd, Integer cols, Integer rows) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        putIfNotNull(params, "pane", pane);
        putIfNotNull(params, "cwd", cwd);
        putIfNotNull(params, "cols", cols);
        putIfNotNull(params, "rows", rows);
        return new SurfaceResult(asLong(request("new-tab", params).get("surface")));
    }

    public SurfaceResult newBrowserTab(String url, Long pane, Integer cols, Integer rows) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("url", url);
        putIfNotNull(params, "pane", pane);
        putIfNotNull(params, "cols", cols);
        putIfNotNull(params, "rows", rows);
        return new SurfaceResult(asLong(request("new-browser-tab", params).get("surface")));
    }

    public SurfaceResult newWorkspace(NewWorkspaceRequest request) throws CmuxException {
        return new SurfaceResult(asLong(request("new-workspace", request.toMap()).get("surface")));
    }

    public SurfaceResult newScreen(Long workspace, Integer cols, Integer rows) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        putIfNotNull(params, "workspace", workspace);
        putIfNotNull(params, "cols", cols);
        putIfNotNull(params, "rows", rows);
        return new SurfaceResult(asLong(request("new-screen", params).get("surface")));
    }

    public SurfaceResult split(long pane, String dir, Integer cols, Integer rows) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("pane", pane);
        params.put("dir", dir);
        putIfNotNull(params, "cols", cols);
        putIfNotNull(params, "rows", rows);
        return new SurfaceResult(asLong(request("split", params).get("surface")));
    }

    public void setRatio(long pane, String dir, double ratio) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("pane", pane);
        params.put("dir", dir);
        params.put("ratio", ratio);
        request("set-ratio", params);
    }

    public void setDefaultColors(String fg, String bg) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        putIfNotNull(params, "fg", fg);
        putIfNotNull(params, "bg", bg);
        request("set-default-colors", params);
    }

    public void closeSurface(long surface) throws CmuxException {
        request("close-surface", surfaceParams(surface));
    }

    public void closePane(long pane) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("pane", pane);
        request("close-pane", params);
    }

    public void closeScreen(long screen) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("screen", screen);
        request("close-screen", params);
    }

    public void renameSurface(long surface, String name) throws CmuxException {
        Map<String, Object> params = surfaceParams(surface);
        params.put("name", name);
        request("rename-surface", params);
    }

    public void renamePane(long pane, String name) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("pane", pane);
        params.put("name", name);
        request("rename-pane", params);
    }

    public void renameScreen(long screen, String name) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("screen", screen);
        params.put("name", name);
        request("rename-screen", params);
    }

    public void renameWorkspace(long workspace, String name) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("workspace", workspace);
        params.put("name", name);
        request("rename-workspace", params);
    }

    public ResizeSurfaceResult resizeSurface(long surface, int cols, int rows) throws CmuxException {
        Map<String, Object> params = surfaceParams(surface);
        params.put("cols", cols);
        params.put("rows", rows);
        return ResizeSurfaceResult.from(request("resize-surface", params));
    }

    public void closeWorkspace(long workspace) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("workspace", workspace);
        request("close-workspace", params);
    }

    public void focusPane(long pane) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("pane", pane);
        request("focus-pane", params);
    }

    public void selectTab(Long pane, Integer index, Integer delta) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        putIfNotNull(params, "pane", pane);
        putIfNotNull(params, "index", index);
        putIfNotNull(params, "delta", delta);
        request("select-tab", params);
    }

    public void selectScreen(Integer index, Integer delta) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        putIfNotNull(params, "index", index);
        putIfNotNull(params, "delta", delta);
        request("select-screen", params);
    }

    public void selectWorkspace(Integer index, Integer delta) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        putIfNotNull(params, "index", index);
        putIfNotNull(params, "delta", delta);
        request("select-workspace", params);
    }

    public void moveTab(long surface, long pane, int index) throws CmuxException {
        Map<String, Object> params = surfaceParams(surface);
        params.put("pane", pane);
        params.put("index", index);
        request("move-tab", params);
    }

    public void moveWorkspace(long workspace, int index) throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("workspace", workspace);
        params.put("index", index);
        request("move-workspace", params);
    }

    public void scrollSurface(long surface, int delta) throws CmuxException {
        Map<String, Object> params = surfaceParams(surface);
        params.put("delta", delta);
        request("scroll-surface", params);
    }

    public CmuxStream subscribe() throws CmuxException {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("id", nextId());
        params.put("cmd", "subscribe");
        return CmuxStream.open(socketPath, timeout, params);
    }

    public CmuxStream attachSurface(long surface) throws CmuxException {
        int negotiated = protocol != null ? protocol : identify().protocol();
        if (negotiated > 8 || (negotiated > 5 && !allowProtocolV6Attach)) {
            throw new CmuxProtocolMismatchException("unsupported attach protocol " + negotiated);
        }
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("cmd", "attach-surface");
        params.put("surface", surface);
        params.put("id", nextId());
        return CmuxStream.open(socketPath, timeout, params);
    }

    @SuppressWarnings("unchecked")
    public Map<String, Object> sendRaw(Map<String, Object> request) throws CmuxException {
        Map<String, Object> payload = new LinkedHashMap<>(request);
        if (!payload.containsKey("id")) {
            payload.put("id", nextId());
        }
        Object id = payload.get("id");
        connection.send(payload);
        while (true) {
            Map<String, Object> response = connection.recv(timeout);
            if (response.containsKey("event")) {
                continue;
            }
            if (response.containsKey("id") && !idsEqual(response.get("id"), id)) {
                continue;
            }
            return response;
        }
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> request(String cmd, Map<String, Object> params) throws CmuxException {
        Map<String, Object> request = new LinkedHashMap<>(params);
        request.put("id", nextId());
        request.put("cmd", cmd);
        Map<String, Object> response = sendRaw(request);
        if (Boolean.TRUE.equals(response.get("ok"))) {
            Object data = response.get("data");
            if (data instanceof Map<?, ?> map) {
                return (Map<String, Object>) map;
            }
            return new LinkedHashMap<>();
        }
        throw new CmuxCommandException(asString(response.getOrDefault("error", "unknown error")), response.get("id"));
    }

    private long nextId() {
        return nextId++;
    }

    @Override
    public void close() throws CmuxException {
        connection.close();
    }

    static Map<String, Object> surfaceParams(long surface) {
        Map<String, Object> params = new LinkedHashMap<>();
        params.put("surface", surface);
        return params;
    }

    static void putIfNotNull(Map<String, Object> params, String key, Object value) {
        if (value != null) {
            params.put(key, value);
        }
    }

    static String asString(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    static long asLong(Object value) {
        if (value instanceof Number number) {
            return number.longValue();
        }
        return Long.parseLong(String.valueOf(value));
    }

    static boolean idsEqual(Object left, Object right) {
        if (left instanceof Number leftNumber && right instanceof Number rightNumber) {
            return Double.compare(leftNumber.doubleValue(), rightNumber.doubleValue()) == 0;
        }
        return left == null ? right == null : left.equals(right);
    }

    static final class JsonLineConnection implements AutoCloseable {
        private final SocketChannel channel;
        private final ByteArrayOutputStream buffer = new ByteArrayOutputStream();

        private JsonLineConnection(SocketChannel channel) {
            this.channel = channel;
        }

        static JsonLineConnection connect(String socketPath) throws CmuxException {
            try {
                SocketChannel channel = SocketChannel.open(StandardProtocolFamily.UNIX);
                channel.connect(UnixDomainSocketAddress.of(socketPath));
                return new JsonLineConnection(channel);
            } catch (IOException err) {
                throw new CmuxTransportException("cannot connect to session socket " + socketPath, err);
            }
        }

        void send(Map<String, Object> value) throws CmuxException {
            byte[] data = (Json.stringify(value) + "\n").getBytes(StandardCharsets.UTF_8);
            try {
                ByteBuffer byteBuffer = ByteBuffer.wrap(data);
                while (byteBuffer.hasRemaining()) {
                    channel.write(byteBuffer);
                }
            } catch (IOException err) {
                throw new CmuxTransportException("socket write failed", err);
            }
        }

        @SuppressWarnings("unchecked")
        Map<String, Object> recv(Duration timeout) throws CmuxException {
            long deadline = System.nanoTime() + timeout.toNanos();
            try {
                Selector selector = null;
                SelectionKey key = null;
                channel.configureBlocking(false);
                try {
                    selector = Selector.open();
                    key = channel.register(selector, SelectionKey.OP_READ);
                    while (System.nanoTime() < deadline) {
                        String line = takeLine();
                        if (line != null) {
                            Object value = Json.parse(line);
                            if (value instanceof Map<?, ?> map) {
                                return (Map<String, Object>) map;
                            }
                            throw new CmuxDecodeException("server sent non-object JSON", null);
                        }
                        long remainingNanos = deadline - System.nanoTime();
                        if (remainingNanos <= 0) {
                            break;
                        }
                        int ready = selector.select(Math.max(1, Duration.ofNanos(remainingNanos).toMillis()));
                        if (ready == 0) {
                            continue;
                        }
                        selector.selectedKeys().clear();
                        ByteBuffer bytes = ByteBuffer.allocate(4096);
                        int read = channel.read(bytes);
                        if (read < 0) {
                            throw new CmuxTransportException("session socket closed");
                        }
                        if (read == 0) {
                            continue;
                        }
                        bytes.flip();
                        while (bytes.hasRemaining()) {
                            buffer.write(bytes.get());
                        }
                    }
                    throw new CmuxTimeoutException("session did not respond");
                } finally {
                    if (key != null) {
                        key.cancel();
                    }
                    if (selector != null) {
                        selector.close();
                    }
                    channel.configureBlocking(true);
                }
            } catch (JsonException err) {
                throw new CmuxDecodeException("bad JSON from server", err);
            } catch (IOException err) {
                throw new CmuxTransportException("socket read failed", err);
            }
        }

        private String takeLine() {
            byte[] bytes = buffer.toByteArray();
            for (int i = 0; i < bytes.length; i++) {
                if (bytes[i] == '\n') {
                    String line = new String(bytes, 0, i, StandardCharsets.UTF_8);
                    buffer.reset();
                    buffer.write(bytes, i + 1, bytes.length - i - 1);
                    return line;
                }
            }
            return null;
        }

        @Override
        public void close() throws CmuxException {
            try {
                channel.close();
            } catch (IOException err) {
                throw new CmuxTransportException("socket close failed", err);
            }
        }
    }

    public static final class Builder {
        private String socketPath;
        private String session = "main";
        private Duration timeout = Duration.ofSeconds(10);
        private boolean allowProtocolV6Attach = true;

        public Builder socketPath(String socketPath) {
            this.socketPath = socketPath;
            return this;
        }

        public Builder session(String session) {
            this.session = session;
            return this;
        }

        public Builder timeout(Duration timeout) {
            this.timeout = timeout;
            return this;
        }

        public Builder allowProtocolV6Attach(boolean allowProtocolV6Attach) {
            this.allowProtocolV6Attach = allowProtocolV6Attach;
            return this;
        }

        public CmuxClient build() throws CmuxException {
            return new CmuxClient(this);
        }
    }

    public static final class CmuxStream implements AutoCloseable {
        private final JsonLineConnection connection;
        private final ArrayDeque<CmuxEvent> buffered;
        private final Map<String, Object> responseData;
        private boolean finished;

        private CmuxStream(
            JsonLineConnection connection,
            ArrayDeque<CmuxEvent> buffered,
            Map<String, Object> responseData
        ) {
            this.connection = connection;
            this.buffered = buffered;
            this.responseData = responseData;
        }

        public Map<String, Object> responseData() { return Map.copyOf(responseData); }

        static CmuxStream open(String socketPath, Duration timeout, Map<String, Object> request) throws CmuxException {
            JsonLineConnection connection = JsonLineConnection.connect(socketPath);
            connection.send(request);
            ArrayDeque<CmuxEvent> buffered = new ArrayDeque<>();
            Object id = request.get("id");
            while (true) {
                Map<String, Object> response = connection.recv(timeout);
                if (response.containsKey("event")) {
                    CmuxEvent event = CmuxEvent.from(response);
                    buffered.add(event);
                    if ("attach-surface".equals(request.get("cmd")) && event instanceof VtStateEvent) {
                        return new CmuxStream(connection, buffered, new LinkedHashMap<>());
                    }
                    continue;
                }
                if (response.containsKey("id") && !idsEqual(response.get("id"), id)) {
                    continue;
                }
                if (Boolean.TRUE.equals(response.get("ok"))) {
                    Object data = response.get("data");
                    Map<String, Object> responseData = data instanceof Map<?, ?>
                        ? TopologyWire.object(data, "stream response data")
                        : new LinkedHashMap<>();
                    return new CmuxStream(connection, buffered, responseData);
                }
                if (Boolean.FALSE.equals(response.get("ok"))) {
                    throw new CmuxCommandException(asString(response.get("error")), response.get("id"));
                }
            }
        }

        public CmuxEvent next(Duration timeout) throws CmuxException {
            if (finished) {
                throw new CmuxException("stream is closed");
            }
            if (!buffered.isEmpty()) {
                return finishTerminal(buffered.removeFirst());
            }
            while (true) {
                Map<String, Object> response = connection.recv(timeout);
                if (response.containsKey("event")) {
                    return finishTerminal(CmuxEvent.from(response));
                }
            }
        }

        private CmuxEvent finishTerminal(CmuxEvent event) throws CmuxException {
            if (event instanceof OverflowEvent
                || event instanceof TopologyResnapshotRequired
                || "detached".equals(event.event())) {
                finished = true;
                connection.close();
            }
            return event;
        }

        @Override
        public void close() throws CmuxException {
            connection.close();
        }
    }
}
