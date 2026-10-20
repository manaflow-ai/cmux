package com.cmux.raw;

import com.cmux.raw.CreateWorkspaceRequest;
import com.cmux.raw.ReadScrollbackResult;
import com.cmux.raw.RenderRow;
import com.cmux.raw.RenderRun;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

public final class ErgonomicsTest {
    public static void main(String[] args) throws Exception {
        rendersPlainText();
        readsBoundedScrollbackTail();
        workspaceLeaseClosesOnce();
    }

    private static void rendersPlainText() {
        RenderRun first = renderRun("hello ");
        RenderRun second = renderRun("世界");
        RenderRow row = RenderRow.builder()
            .row(7)
            .runs(List.of(first, second))
            .build();
        RenderRow next = RenderRow.builder()
            .row(8)
            .runs(List.of(renderRun("next")))
            .build();

        check("hello ".equals(RenderText.plainText(first)), "run plain text");
        check("hello 世界".equals(RenderText.plainText(row)), "row plain text");
        check(
            "hello 世界\nnext".equals(RenderText.plainText(List.of(row, next))),
            "row list plain text"
        );
    }

    private static void readsBoundedScrollbackTail() throws Exception {
        try (Harness harness = new Harness(server -> {
            try (SocketChannel connection = server.accept()) {
                Map<String, Object> identify = readObject(connection);
                check("identify".equals(identify.get("cmd")), "tail identify command");
                writeObject(connection, identifyResponse(identify.get("id")));

                Map<String, Object> probe = readObject(connection);
                check("read-scrollback".equals(probe.get("cmd")), "tail probe command");
                check(number(probe, "surface") == 9, "tail probe surface");
                check(number(probe, "start") == 0, "tail probe start");
                check(number(probe, "count") == 0, "tail probe count");
                writeObject(
                    connection,
                    success(probe.get("id"), Map.of(
                        "epoch", 1L,
                        "rows", List.of(),
                        "start", 0L,
                        "total", 10L
                    ))
                );

                Map<String, Object> page = readObject(connection);
                check("read-scrollback".equals(page.get("cmd")), "tail page command");
                check(number(page, "surface") == 9, "tail page surface");
                check(number(page, "start") == 7, "tail page start");
                check(number(page, "count") == 3, "tail page count");
                writeObject(
                    connection,
                    success(page.get("id"), Map.of(
                        "epoch", 1L,
                        "rows", List.of(
                            renderRow(0, "eight"),
                            renderRow(1, "nine"),
                            renderRow(2, "ten")
                        ),
                        "start", 7L,
                        "total", 10L
                    ))
                );

                check(
                    connection.read(ByteBuffer.allocate(1)) < 0,
                    "invalid tail counts do not send requests"
                );
            }
        })) {
            try (CmuxClient client = CmuxClient.builder()
                    .socketPath(harness.socket())
                    .timeout(Duration.ofSeconds(2))
                    .build()) {
                ReadScrollbackResult tail = client.readScrollbackTail(UInt64.of(9), 3);
                check(tail.start() == 7, "tail result start");
                check(tail.total() == 10, "tail result total");
                check(
                    "eight\nnine\nten".equals(RenderText.plainText(tail.rows())),
                    "tail result text"
                );
                rejectTailCount(client, -1);
                rejectTailCount(client, CmuxClient.MAX_SCROLLBACK_PAGE_ROWS + 1);
            }
            harness.finish();
        }
    }

    private static void workspaceLeaseClosesOnce() throws Exception {
        try (Harness harness = new Harness(server -> {
            try (SocketChannel connection = server.accept()) {
                Map<String, Object> identify = readObject(connection);
                check("identify".equals(identify.get("cmd")), "lease identify command");
                writeObject(connection, identifyResponse(identify.get("id")));

                Map<String, Object> create = readObject(connection);
                check("create-workspace".equals(create.get("cmd")), "lease create command");
                check("leased".equals(create.get("name")), "lease create request");
                writeObject(connection, success(create.get("id"), workspaceResult(true)));

                Map<String, Object> close = readObject(connection);
                check("close-workspace".equals(close.get("cmd")), "lease close command");
                check(number(close, "workspace") == 42, "lease closes owned workspace");
                writeObject(connection, success(close.get("id"), workspaceResult(true)));

                check(
                    connection.read(ByteBuffer.allocate(1)) < 0,
                    "successful lease close is sent once"
                );
            }
        })) {
            try (CmuxClient client = CmuxClient.builder()
                    .socketPath(harness.socket())
                    .timeout(Duration.ofSeconds(2))
                    .build()) {
                WorkspaceLease lease = client.createWorkspaceLease(
                    CreateWorkspaceRequest.builder().name("leased").build()
                );
                check(lease.workspace().equals(UInt64.of(42)), "lease workspace id");
                check(lease.key().equals("workspace-key"), "lease workspace key");
                check(!lease.isClosed(), "new lease open");
                lease.close();
                check(lease.isClosed(), "lease closed");
                lease.close();
            }
            harness.finish();
        }
    }

    private static void rejectTailCount(CmuxClient client, int count) throws CmuxException {
        try {
            client.readScrollbackTail(UInt64.of(9), count);
            throw new AssertionError("accepted invalid tail count " + count);
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains("count"), "tail count validation message");
        }
    }

    private static RenderRun renderRun(String text) {
        return RenderRun.builder()
            .attrs(0)
            .bg(null)
            .fg(null)
            .text(text)
            .build();
    }

    private static Map<String, Object> renderRow(long row, String text) {
        LinkedHashMap<String, Object> run = new LinkedHashMap<>();
        run.put("attrs", 0L);
        run.put("bg", null);
        run.put("fg", null);
        run.put("text", text);
        return Map.of("row", row, "runs", List.of(run));
    }

    private static Map<String, Object> identifyResponse(Object id) {
        return success(id, Map.of(
            "app", "cmux-tui",
            "version", "test",
            "protocol", 10L,
            "capabilities", List.of("workspace-registry-v1"),
            "session", "java-test",
            "pid", 1L
        ));
    }

    private static Map<String, Object> workspaceResult(boolean changed) {
        return Map.of(
            "changed", changed,
            "generation", "generation-1",
            "index", 0L,
            "key", "workspace-key",
            "registry_id", "registry-1",
            "replayed", false,
            "workspace", 42L,
            "workspace_revision", 1L
        );
    }

    private static Map<String, Object> success(Object id, Object data) {
        LinkedHashMap<String, Object> response = new LinkedHashMap<>();
        response.put("id", id);
        response.put("ok", true);
        response.put("data", data);
        return response;
    }

    private static long number(Map<String, Object> object, String key) {
        return ((Number) object.get(key)).longValue();
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> readObject(SocketChannel client) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        ByteBuffer one = ByteBuffer.allocate(1);
        while (client.read(one) >= 0) {
            one.flip();
            if (one.hasRemaining()) {
                byte value = one.get();
                if (value == '\n') {
                    return (Map<String, Object>) Json.parse(bytes.toByteArray(), 128);
                }
                bytes.write(value);
            }
            one.clear();
        }
        throw new IOException("client closed before request");
    }

    private static void writeObject(SocketChannel client, Map<String, Object> value)
        throws IOException {
        ByteBuffer bytes = ByteBuffer.wrap(
            (Json.stringify(value) + "\n").getBytes(StandardCharsets.UTF_8)
        );
        while (bytes.hasRemaining()) {
            client.write(bytes);
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    @FunctionalInterface
    private interface ServerBehavior {
        void run(ServerSocketChannel server) throws Exception;
    }

    private static final class Harness implements AutoCloseable {
        private final Path socket;
        private final ServerSocketChannel server;
        private final Thread thread;
        private final AtomicReference<Throwable> failure = new AtomicReference<>();

        Harness(ServerBehavior behavior) throws Exception {
            socket = Files.createTempFile("cmux-java-ergonomics", ".sock");
            Files.deleteIfExists(socket);
            server = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
            server.bind(UnixDomainSocketAddress.of(socket));
            thread = new Thread(() -> {
                try {
                    behavior.run(server);
                } catch (Throwable error) {
                    failure.set(error);
                }
            }, "cmux-java-ergonomics-server");
            thread.start();
        }

        Path socket() {
            return socket;
        }

        void finish() throws Exception {
            thread.join(5_000);
            check(!thread.isAlive(), "ergonomics server finished");
            Throwable error = failure.get();
            if (error != null) {
                if (error instanceof Exception exception) {
                    throw exception;
                }
                throw new AssertionError("ergonomics server failed", error);
            }
        }

        @Override
        public void close() {
            try {
                server.close();
            } catch (IOException error) {
                failure.compareAndSet(null, error);
            }
            try {
                thread.join(1_000);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                failure.compareAndSet(null, error);
            }
            try {
                Files.deleteIfExists(socket);
            } catch (IOException error) {
                failure.compareAndSet(null, error);
            }
        }
    }
}
