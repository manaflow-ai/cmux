package com.cmux.raw;

import com.cmux.raw.ProtocolEvent;
import com.cmux.raw.SubscribeEvent;
import com.cmux.raw.UnknownEvent;
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
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public final class LifecycleTest {
    public static void main(String[] args) throws Exception {
        rawRequestPreservesEnvelope();
        unknownEventsRemainForwardCompatible();
        closeUnblocksPendingStreamRead();
        closeUnblocksPendingCommandRead();
        enforcesMessageLimits();
        enforcesPreAckStreamBufferLimit();
        rejectsInvalidStreamBufferLimits();
    }

    private static void rawRequestPreservesEnvelope() throws Exception {
        try (Harness harness = new Harness(server -> {
            try (SocketChannel client = server.accept()) {
                Map<String, Object> request = readObject(client);
                check("ping".equals(request.get("cmd")), "raw command");
                writeObject(client, success(request.get("id"), Map.of(
                    "protocol", 10L,
                    "maximum", UInt64.MAX_VALUE.toBigInteger()
                )));
            }
        })) {
            try (CmuxClient client = CmuxClient.builder()
                    .socketPath(harness.socket())
                    .timeout(Duration.ofSeconds(2))
                    .build()) {
                Map<String, Object> response = client.rawRequest(Map.of("cmd", "ping"));
                @SuppressWarnings("unchecked")
                Map<String, Object> data = (Map<String, Object>) response.get("data");
                check(
                    Wire.uint64(data.get("maximum"), "maximum").equals(UInt64.MAX_VALUE),
                    "response uint64 precision"
                );
            }
            harness.finish();
        }
    }

    private static void unknownEventsRemainForwardCompatible() throws Exception {
        try (Harness harness = new Harness(server -> {
            try (SocketChannel commands = server.accept()) {
                Map<String, Object> identify = readObject(commands);
                writeObject(commands, success(identify.get("id"), Map.of(
                    "app", "cmux-tui",
                    "version", "test",
                    "protocol", 10L,
                    "capabilities", java.util.List.of(),
                    "session", "java-test",
                    "pid", 1L
                )));
                try (SocketChannel stream = server.accept()) {
                    Map<String, Object> subscribe = readObject(stream);
                    writeObject(stream, success(subscribe.get("id"), Map.of()));
                    writeObject(stream, Map.of("event", "future-event", "answer", 42L));
                }
            }
        })) {
            try (CmuxClient client = CmuxClient.builder()
                    .socketPath(harness.socket())
                    .timeout(Duration.ofSeconds(2))
                    .build();
                 CmuxStream<SubscribeEvent> stream = client.subscribeEvents()) {
                ProtocolEvent event = stream.next();
                check(event instanceof UnknownEvent, "unknown event fallback type");
                check(
                    ((UnknownEvent) event).raw().get("answer").equals(42L),
                    "unknown event raw payload"
                );
            }
            harness.finish();
        }
    }

    private static void closeUnblocksPendingStreamRead() throws Exception {
        try (Harness harness = new Harness(server -> {
            try (SocketChannel commands = server.accept()) {
                Map<String, Object> identify = readObject(commands);
                writeObject(commands, success(identify.get("id"), Map.of(
                    "app", "cmux-tui",
                    "version", "test",
                    "protocol", 10L,
                    "capabilities", java.util.List.of(),
                    "session", "java-test",
                    "pid", 1L
                )));
                try (SocketChannel stream = server.accept()) {
                    Map<String, Object> subscribe = readObject(stream);
                    writeObject(stream, success(subscribe.get("id"), Map.of()));
                    while (stream.read(ByteBuffer.allocate(1)) >= 0) {
                        // Wait for the SDK to close the stream.
                    }
                }
            }
        })) {
            try (CmuxClient client = CmuxClient.builder()
                    .socketPath(harness.socket())
                    .timeout(Duration.ofSeconds(30))
                    .build()) {
                CmuxStream<SubscribeEvent> stream = client.subscribeEvents();
                AtomicReference<Throwable> outcome = new AtomicReference<>();
                CountDownLatch readStarted = new CountDownLatch(1);
                Thread reader = new Thread(() -> {
                    try {
                        stream.next(Duration.ofSeconds(30), readStarted::countDown);
                        outcome.set(new AssertionError("read returned without an event"));
                    } catch (CmuxTransportException expected) {
                        outcome.set(expected);
                    } catch (Throwable error) {
                        outcome.set(error);
                    }
                }, "cmux-java-close-unblocks");
                reader.start();
                boolean readReady = readStarted.await(2, TimeUnit.SECONDS);
                stream.close();
                reader.join(2_000);
                check(readReady, "stream read started");
                check(!reader.isAlive(), "close unblocks read");
                check(outcome.get() instanceof CmuxTransportException, "close reports transport error");
            }
            harness.finish();
        }
    }

    private static void enforcesMessageLimits() throws Exception {
        try (Harness harness = new Harness(server -> {
            try (SocketChannel client = server.accept()) {
                Map<String, Object> request = readObject(client);
                writeObject(client, success(request.get("id"), Map.of("text", "x".repeat(512))));
            }
        })) {
            try (CmuxClient client = CmuxClient.builder()
                    .socketPath(harness.socket())
                    .timeout(Duration.ofSeconds(2))
                    .maxResponseBytes(128)
                    .build()) {
                try {
                    client.rawRequest(Map.of("cmd", "read-screen"));
                    throw new AssertionError("accepted oversized response");
                } catch (CmuxTransportException expected) {
                    check(expected.getMessage().contains("exceeds"), "oversized response error");
                }
            }
            harness.finish();
        }

        try (Harness harness = new Harness(server -> {
            SocketChannel accepted = server.accept();
            try (accepted) {
                while (accepted.read(ByteBuffer.allocate(1)) >= 0) {
                    // Wait for the client to close after rejecting the request locally.
                }
            }
        })) {
            try (CmuxClient client = CmuxClient.builder()
                    .socketPath(harness.socket())
                    .timeout(Duration.ofSeconds(2))
                    .maxRequestBytes(64)
                    .build()) {
                try {
                    client.rawRequest(Map.of("cmd", "send", "text", "x".repeat(512)));
                    throw new AssertionError("accepted oversized request");
                } catch (CmuxTransportException expected) {
                    check(expected.getMessage().contains("exceeds"), "oversized request error");
                }
            }
            harness.finish();
        }
    }

    private static void closeUnblocksPendingCommandRead() throws Exception {
        CountDownLatch readStarted = new CountDownLatch(1);
        try (Harness harness = new Harness(server -> {
            try (SocketChannel client = server.accept()) {
                readObject(client);
                while (client.read(ByteBuffer.allocate(1)) >= 0) {
                    // Wait for CmuxClient.close().
                }
            }
        })) {
            CmuxClient client = CmuxClient.builder()
                    .socketPath(harness.socket())
                    .timeout(Duration.ofSeconds(30))
                    .build();
            try {
                AtomicReference<Throwable> outcome = new AtomicReference<>();
                Thread reader = new Thread(() -> {
                    try {
                        client.rawRequest(
                            Map.of("cmd", "ping"),
                            readStarted::countDown
                        );
                        outcome.set(new AssertionError("command returned without a response"));
                    } catch (CmuxTransportException expected) {
                        outcome.set(expected);
                    } catch (Throwable error) {
                        outcome.set(error);
                    }
                }, "cmux-java-client-close-unblocks");
                reader.start();
                boolean readReady = readStarted.await(2, TimeUnit.SECONDS);
                client.close();
                reader.join(2_000);
                check(readReady, "client entered command read wait");
                check(!reader.isAlive(), "client close unblocks command read");
                check(outcome.get() instanceof CmuxTransportException, "client close transport error");
            } finally {
                client.close();
            }
            harness.finish();
        }
    }

    private static void enforcesPreAckStreamBufferLimit() throws Exception {
        try (Harness harness = new Harness(server -> {
            try (SocketChannel commands = server.accept()) {
                Map<String, Object> identify = readObject(commands);
                writeObject(commands, success(identify.get("id"), Map.of(
                    "app", "cmux-tui",
                    "version", "test",
                    "protocol", 10L,
                    "capabilities", java.util.List.of(),
                    "session", "java-test",
                    "pid", 1L
                )));
                try (SocketChannel stream = server.accept()) {
                    readObject(stream);
                    writeObject(stream, Map.of("event", "status", "message", "one"));
                    writeObject(stream, Map.of("event", "status", "message", "two"));
                    writeObject(stream, Map.of("event", "status", "message", "three"));
                    check(
                        stream.read(ByteBuffer.allocate(1)) < 0,
                        "pre-ack overflow closes stream connection"
                    );
                }
            }
        })) {
            try (CmuxClient client = CmuxClient.builder()
                    .socketPath(harness.socket())
                    .timeout(Duration.ofSeconds(2))
                    .maxBufferedStreamEvents(2)
                    .build()) {
                try {
                    client.subscribeEvents();
                    throw new AssertionError("accepted too many pre-ack stream events");
                } catch (CmuxStreamBufferOverflowException expected) {
                    check(expected.limit() == 2, "stream buffer exception limit");
                }
            }
            harness.finish();
        }
    }

    private static void rejectsInvalidStreamBufferLimits() {
        for (int limit : new int[] {0, -1}) {
            try {
                CmuxClient.builder().maxBufferedStreamEvents(limit);
                throw new AssertionError("accepted invalid stream buffer limit " + limit);
            } catch (IllegalArgumentException expected) {
                check(
                    expected.getMessage().contains("maxBufferedStreamEvents"),
                    "invalid stream buffer limit error"
                );
            }
        }
    }

    private static Map<String, Object> success(Object id, Object data) {
        LinkedHashMap<String, Object> response = new LinkedHashMap<>();
        response.put("id", id);
        response.put("ok", true);
        response.put("data", data);
        return response;
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

    private static void writeObject(SocketChannel client, Map<String, Object> value) throws IOException {
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
            socket = Files.createTempFile("cmux-java-sdk", ".sock");
            Files.deleteIfExists(socket);
            server = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
            server.bind(UnixDomainSocketAddress.of(socket));
            thread = new Thread(() -> {
                try {
                    behavior.run(server);
                } catch (Throwable error) {
                    failure.set(error);
                }
            }, "cmux-java-test-server");
            thread.start();
        }

        Path socket() {
            return socket;
        }

        void finish() throws Exception {
            thread.join(5_000);
            check(!thread.isAlive(), "test server finished");
            Throwable error = failure.get();
            if (error != null) {
                if (error instanceof Exception exception) {
                    throw exception;
                }
                throw new AssertionError("test server failed", error);
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
