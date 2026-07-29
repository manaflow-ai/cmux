package com.cmux;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.CancelledKeyException;
import java.nio.channels.ClosedChannelException;
import java.nio.channels.ClosedSelectorException;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Arrays;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/** Bounded UTF-8 JSON-lines connection over a JDK Unix-domain socket. */
final class JsonLineConnection implements AutoCloseable {
    static final int DEFAULT_MAX_REQUEST_BYTES = 4_194_304;
    static final int DEFAULT_MAX_RESPONSE_BYTES = 16_777_216;

    private final SocketChannel channel;
    private final Selector selector;
    private final int maxRequestBytes;
    private final int maxResponseBytes;
    private final int maxJsonDepth;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final Object writeLock = new Object();
    private final Object readLock = new Object();
    private final ByteArrayOutputStream received = new ByteArrayOutputStream(8192);

    private JsonLineConnection(
        SocketChannel channel,
        Selector selector,
        int maxRequestBytes,
        int maxResponseBytes,
        int maxJsonDepth
    ) {
        this.channel = channel;
        this.selector = selector;
        this.maxRequestBytes = maxRequestBytes;
        this.maxResponseBytes = maxResponseBytes;
        this.maxJsonDepth = maxJsonDepth;
    }

    static JsonLineConnection connect(
        Path socket,
        int maxRequestBytes,
        int maxResponseBytes,
        int maxJsonDepth
    ) throws CmuxTransportException {
        SocketChannel channel = null;
        Selector selector = null;
        try {
            channel = SocketChannel.open(StandardProtocolFamily.UNIX);
            channel.configureBlocking(true);
            channel.connect(UnixDomainSocketAddress.of(socket));
            channel.configureBlocking(false);
            selector = Selector.open();
            channel.register(selector, SelectionKey.OP_READ);
            return new JsonLineConnection(
                channel,
                selector,
                positive(maxRequestBytes, "maxRequestBytes"),
                positive(maxResponseBytes, "maxResponseBytes"),
                positive(maxJsonDepth, "maxJsonDepth")
            );
        } catch (IOException | RuntimeException error) {
            closeQuietly(selector);
            closeQuietly(channel);
            throw new CmuxTransportException("cannot connect to session socket " + socket, error);
        }
    }

    void send(Map<String, Object> value) throws CmuxException {
        byte[] message;
        try {
            message = Json.stringify(Wire.encode(value), maxJsonDepth).getBytes(StandardCharsets.UTF_8);
        } catch (JsonException | IllegalArgumentException error) {
            throw new CmuxDecodeException("cannot encode request", error);
        }
        if (message.length > maxRequestBytes) {
            throw new CmuxTransportException(
                "request exceeds " + maxRequestBytes + " bytes"
            );
        }
        synchronized (writeLock) {
            ensureOpen();
            try {
                writeFully(ByteBuffer.wrap(message));
                writeFully(ByteBuffer.wrap(new byte[] {'\n'}));
            } catch (ClosedChannelException error) {
                throw new CmuxTransportException("connection is closed", error);
            } catch (IOException error) {
                throw new CmuxTransportException("socket write failed", error);
            }
        }
    }

    Map<String, Object> receive(Duration timeout) throws CmuxException {
        if (timeout == null || timeout.isNegative() || timeout.isZero()) {
            throw new IllegalArgumentException("timeout must be positive");
        }
        synchronized (readLock) {
            ensureOpen();
            long deadline = deadline(timeout);
            while (true) {
                byte[] line = takeLine();
                if (line != null) {
                    if (isBlank(line)) {
                        continue;
                    }
                    Object decoded;
                    try {
                        decoded = Json.parse(line, maxJsonDepth);
                    } catch (JsonException error) {
                        throw new CmuxDecodeException("bad JSON from server", error);
                    }
                    return Wire.object(decoded, "server message");
                }
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) {
                    throw new CmuxTimeoutException("session did not respond before timeout");
                }
                try {
                    int ready = selector.select(Math.max(1, Duration.ofNanos(remaining).toMillis()));
                    if (closed.get()) {
                        throw new CmuxTransportException("connection is closed");
                    }
                    if (ready == 0) {
                        continue;
                    }
                    selector.selectedKeys().clear();
                    ByteBuffer chunk = ByteBuffer.allocate(8192);
                    int count = channel.read(chunk);
                    if (count < 0) {
                        throw new CmuxTransportException("session socket closed");
                    }
                    if (count == 0) {
                        continue;
                    }
                    chunk.flip();
                    received.write(chunk.array(), chunk.position(), chunk.remaining());
                    if (received.size() > maxResponseBytes && !containsNewline(received)) {
                        close();
                        throw new CmuxTransportException(
                            "server message exceeds " + maxResponseBytes + " bytes"
                        );
                    }
                } catch (ClosedChannelException | ClosedSelectorException | CancelledKeyException error) {
                    throw new CmuxTransportException("connection is closed", error);
                } catch (IOException error) {
                    if (closed.get()) {
                        throw new CmuxTransportException("connection is closed", error);
                    }
                    throw new CmuxTransportException("socket read failed", error);
                }
            }
        }
    }

    private void writeFully(ByteBuffer bytes) throws IOException, CmuxTransportException {
        while (bytes.hasRemaining()) {
            int written = channel.write(bytes);
            if (written > 0) {
                continue;
            }
            if (closed.get()) {
                throw new ClosedChannelException();
            }
            try {
                Thread.sleep(1);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new CmuxTransportException("interrupted during socket write", error);
            }
        }
    }

    private byte[] takeLine() throws CmuxTransportException {
        byte[] bytes = received.toByteArray();
        for (int index = 0; index < bytes.length; index++) {
            if (bytes[index] != '\n') {
                continue;
            }
            int length = index;
            if (length > 0 && bytes[length - 1] == '\r') {
                length--;
            }
            if (length > maxResponseBytes) {
                close();
                throw new CmuxTransportException(
                    "server message exceeds " + maxResponseBytes + " bytes"
                );
            }
            byte[] line = Arrays.copyOf(bytes, length);
            received.reset();
            received.write(bytes, index + 1, bytes.length - index - 1);
            return line;
        }
        return null;
    }

    private static boolean containsNewline(ByteArrayOutputStream bytes) {
        for (byte value : bytes.toByteArray()) {
            if (value == '\n') {
                return true;
            }
        }
        return false;
    }

    private static boolean isBlank(byte[] bytes) {
        for (byte value : bytes) {
            if (value != ' ' && value != '\t' && value != '\r') {
                return false;
            }
        }
        return true;
    }

    private static long deadline(Duration timeout) {
        long now = System.nanoTime();
        long nanos;
        try {
            nanos = timeout.toNanos();
        } catch (ArithmeticException error) {
            return Long.MAX_VALUE;
        }
        return nanos >= Long.MAX_VALUE - now ? Long.MAX_VALUE : now + nanos;
    }

    private void ensureOpen() throws CmuxTransportException {
        if (closed.get()) {
            throw new CmuxTransportException("connection is closed");
        }
    }

    @Override
    public void close() {
        if (!closed.compareAndSet(false, true)) {
            return;
        }
        selector.wakeup();
        closeQuietly(channel);
        closeQuietly(selector);
    }

    private static int positive(int value, String name) {
        if (value < 1) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return value;
    }

    private static void closeQuietly(AutoCloseable closeable) {
        if (closeable == null) {
            return;
        }
        try {
            closeable.close();
        } catch (Exception ignored) {
            // best effort
        }
    }
}
