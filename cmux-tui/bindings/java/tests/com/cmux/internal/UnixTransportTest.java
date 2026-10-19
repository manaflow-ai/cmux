package com.cmux.internal;

import com.cmux.ProtocolError;
import com.cmux.raw.Json;
import com.cmux.raw.JsonException;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.ByteChannel;
import java.nio.channels.ClosedChannelException;
import java.nio.channels.ClosedByInterruptException;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public final class UnixTransportTest {
    private static final int MAX_REQUEST_BYTES = 1_048_576;
    private static final int MAX_RESPONSE_BYTES = 1_048_576;

    public static void main(String[] args) throws Exception {
        boundedConnectUsesUnixChannel();
        rejectsInvalidConnectTimeout();
        interruptedConnectClosesChannel();
        largeFrameUsesBufferedReads();
        coalescedOpenResponsePreservesStreamItem();
        idleReadHasNoTransportDeadline();
        rejectsInvalidUtf8();
        enforcesResponseSizeLimit();
        rejectsEofInsideFrame();
    }

    private static void boundedConnectUsesUnixChannel() throws Exception {
        Path socket = Files.createTempFile("cmux-java-connect", ".sock");
        Files.deleteIfExists(socket);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        CountDownLatch acceptedSignal = new CountDownLatch(1);
        Thread server = null;
        try (ServerSocketChannel listener =
                ServerSocketChannel.open(StandardProtocolFamily.UNIX)) {
            listener.bind(UnixDomainSocketAddress.of(socket));
            server = new Thread(() -> {
                try (SocketChannel accepted = listener.accept()) {
                    // The connect path only needs a listener. No protocol frame is required.
                    check(accepted.isOpen(), "connect test accepted channel");
                } catch (Throwable error) {
                    failure.set(error);
                } finally {
                    acceptedSignal.countDown();
                }
            }, "cmux-java-connect-test-server");
            server.start();
            try (SocketChannel client = UnixSocketConnector.open(
                    socket,
                    Duration.ofSeconds(1)
                )) {
                check(client.isBlocking(), "bounded connector returns blocking channel");
            }
            check(
                acceptedSignal.await(2, TimeUnit.SECONDS),
                "connect test server accepted client before listener closes"
            );
        } finally {
            if (server != null) {
                server.join(2_000);
                check(!server.isAlive(), "connect test server stopped");
            }
            Files.deleteIfExists(socket);
        }
        if (failure.get() != null) {
            throw new AssertionError("connect test server failed", failure.get());
        }
    }

    private static void rejectsInvalidConnectTimeout() throws Exception {
        expect(
            IllegalArgumentException.class,
            () -> UnixSocketConnector.open(
                Path.of("/tmp/cmux-java-invalid-connect-timeout"),
                Duration.ZERO
            ),
            "zero connect timeout"
        );
    }

    private static void interruptedConnectClosesChannel() throws Exception {
        Thread.currentThread().interrupt();
        try {
            expect(
                ClosedByInterruptException.class,
                () -> UnixSocketConnector.open(
                    Path.of("/tmp/cmux-java-interrupted-connect"),
                    Duration.ofSeconds(1)
                ),
                "interrupted connect"
            );
            check(
                Thread.currentThread().isInterrupted(),
                "interrupted connect restores interrupt status"
            );
        } finally {
            Thread.interrupted();
        }
    }

    private static void largeFrameUsesBufferedReads() throws Exception {
        String payload = "x".repeat(256_000);
        byte[] response = frame(Map.of("payload", payload));
        CountingChannel channel = new CountingChannel(response);

        try (UnixTransport transport = transport(channel)) {
            Map<String, Object> decoded = transport.receive();
            check(payload.equals(decoded.get("payload")), "large response payload");
        }

        int expectedReads = divideRoundUp(
            response.length,
            UnixTransport.READ_BUFFER_BYTES
        );
        check(
            channel.readCalls() == expectedReads,
            "large response uses one channel read per reusable buffer"
        );
        check(
            channel.readCalls() < response.length / 1_000,
            "large response does not use one channel read per byte"
        );
    }

    private static void coalescedOpenResponsePreservesStreamItem()
            throws Exception {
        byte[] opened = frame(Map.of(
            "protocol", "cmux.protocol/2",
            "type", "response",
            "id", "java-1",
            "ok", true,
            "result", Map.of("stream_id", "stream-test")
        ));
        byte[] item = frame(Map.of(
            "protocol", "cmux.protocol/2",
            "type", "stream_item",
            "stream_id", "stream-test",
            "sequence", "1",
            "item", Map.of("marker", "preserved")
        ));
        CountingChannel channel = new CountingChannel(join(opened, item));

        try (UnixTransport transport = transport(channel)) {
            Map<String, Object> first = transport.receive();
            Map<String, Object> second = transport.receive();
            check("response".equals(first.get("type")), "open response frame");
            check("stream_item".equals(second.get("type")), "stream item frame");
            check(
                channel.readCalls() == 1,
                "coalesced frames share one channel read"
            );
        }
    }

    private static void idleReadHasNoTransportDeadline() throws Exception {
        BlockingChannel channel = new BlockingChannel(
            frame(Map.of("type", "delayed"))
        );
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try (UnixTransport transport = transport(channel)) {
            Future<Map<String, Object>> receive = executor.submit(transport::receive);
            check(
                channel.awaitRead(1, TimeUnit.SECONDS),
                "idle receive reaches channel read"
            );
            check(!receive.isDone(), "idle receive remains pending");
            channel.release();
            check(
                "delayed".equals(receive.get(1, TimeUnit.SECONDS).get("type")),
                "idle receive accepts a delayed frame"
            );
        } finally {
            executor.shutdownNow();
            check(
                executor.awaitTermination(1, TimeUnit.SECONDS),
                "idle receive executor terminates"
            );
        }
    }

    private static void rejectsInvalidUtf8() throws Exception {
        byte[] prefix = "{\"value\":\"".getBytes(StandardCharsets.UTF_8);
        byte[] suffix = "\"}\n".getBytes(StandardCharsets.UTF_8);
        CountingChannel channel = new CountingChannel(
            join(prefix, new byte[] {(byte) 0xc3, 0x28}, suffix)
        );

        try (UnixTransport transport = transport(channel)) {
            expect(
                JsonException.class,
                transport::receive,
                "invalid UTF-8 response"
            );
        }
    }

    private static void enforcesResponseSizeLimit() throws Exception {
        CountingChannel channel = new CountingChannel(
            frame(Map.of("payload", "too large"))
        );

        try (UnixTransport transport = new UnixTransport(
                channel,
                MAX_REQUEST_BYTES,
                8
            )) {
            expect(
                ProtocolError.class,
                transport::receive,
                "oversized response"
            );
            check(!channel.isOpen(), "oversized response closes transport");
        }
    }

    private static void rejectsEofInsideFrame() throws Exception {
        CountingChannel channel = new CountingChannel(
            "{\"incomplete\":true}".getBytes(StandardCharsets.UTF_8)
        );

        try (UnixTransport transport = transport(channel)) {
            IOException error = expect(
                IOException.class,
                transport::receive,
                "EOF inside response frame"
            );
            check(
                "session socket closed".equals(error.getMessage()),
                "EOF reports a closed session socket"
            );
            check(!channel.isOpen(), "EOF closes transport channel");
        }
    }

    private static UnixTransport transport(ByteChannel channel) {
        return new UnixTransport(
            channel,
            MAX_REQUEST_BYTES,
            MAX_RESPONSE_BYTES
        );
    }

    private static byte[] frame(Map<String, Object> value) {
        return (Json.stringify(value) + "\n").getBytes(StandardCharsets.UTF_8);
    }

    private static byte[] join(byte[]... values) {
        ByteArrayOutputStream joined = new ByteArrayOutputStream();
        for (byte[] value : values) {
            joined.writeBytes(value);
        }
        return joined.toByteArray();
    }

    private static int divideRoundUp(int value, int divisor) {
        return (value + divisor - 1) / divisor;
    }

    private static <T extends Throwable> T expect(
        Class<T> type,
        ThrowingAction action,
        String context
    ) throws Exception {
        try {
            action.run();
        } catch (Throwable error) {
            if (type.isInstance(error)) {
                return type.cast(error);
            }
            if (error instanceof ExecutionException execution &&
                    type.isInstance(execution.getCause())) {
                return type.cast(execution.getCause());
            }
            throw new AssertionError(
                context + " threw " + error.getClass().getName(),
                error
            );
        }
        throw new AssertionError(context + " did not throw " + type.getName());
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    @FunctionalInterface
    private interface ThrowingAction {
        void run() throws Exception;
    }

    private static class CountingChannel implements ByteChannel {
        private final byte[] source;
        private int offset;
        private int readCalls;
        private boolean open = true;

        CountingChannel(byte[] source) {
            this.source = source.clone();
        }

        @Override
        public synchronized int read(ByteBuffer destination)
                throws IOException {
            requireOpen();
            readCalls++;
            if (offset == source.length) {
                return -1;
            }
            int count = Math.min(destination.remaining(), source.length - offset);
            destination.put(source, offset, count);
            offset += count;
            return count;
        }

        @Override
        public synchronized int write(ByteBuffer sourceBuffer)
                throws IOException {
            requireOpen();
            int count = sourceBuffer.remaining();
            sourceBuffer.position(sourceBuffer.limit());
            return count;
        }

        @Override
        public synchronized boolean isOpen() {
            return open;
        }

        @Override
        public synchronized void close() {
            open = false;
        }

        synchronized int readCalls() {
            return readCalls;
        }

        private void requireOpen() throws ClosedChannelException {
            if (!open) {
                throw new ClosedChannelException();
            }
        }
    }

    private static final class BlockingChannel extends CountingChannel {
        private final CountDownLatch reading = new CountDownLatch(1);
        private final CountDownLatch released = new CountDownLatch(1);

        BlockingChannel(byte[] source) {
            super(source);
        }

        @Override
        public int read(ByteBuffer destination) throws IOException {
            reading.countDown();
            try {
                released.await();
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new IOException("interrupted while awaiting test frame", error);
            }
            return super.read(destination);
        }

        boolean awaitRead(long timeout, TimeUnit unit)
                throws InterruptedException {
            return reading.await(timeout, unit);
        }

        void release() {
            released.countDown();
        }
    }
}
