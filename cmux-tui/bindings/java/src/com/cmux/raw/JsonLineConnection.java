package com.cmux.raw;

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
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;

/** Bounded UTF-8 JSON-lines connection over a JDK Unix-domain socket. */
final class JsonLineConnection implements AutoCloseable {
    static final int DEFAULT_MAX_REQUEST_BYTES = 4_194_304;
    static final int DEFAULT_MAX_RESPONSE_BYTES = 16_777_216;

    private final SocketChannel channel;
    private final Selector readSelector;
    private final Selector writeSelector;
    private final int maxRequestBytes;
    private final int maxResponseBytes;
    private final int maxJsonDepth;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final Object writeLock = new Object();
    private final Object readLock = new Object();
    private final ByteArrayOutputStream received = new ByteArrayOutputStream(8192);

    private JsonLineConnection(
        SocketChannel channel,
        Selector readSelector,
        Selector writeSelector,
        int maxRequestBytes,
        int maxResponseBytes,
        int maxJsonDepth
    ) {
        this.channel = channel;
        this.readSelector = readSelector;
        this.writeSelector = writeSelector;
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
        Selector readSelector = null;
        Selector writeSelector = null;
        try {
            channel = SocketChannel.open(StandardProtocolFamily.UNIX);
            channel.configureBlocking(true);
            channel.connect(UnixDomainSocketAddress.of(socket));
            channel.configureBlocking(false);
            readSelector = Selector.open();
            writeSelector = Selector.open();
            channel.register(readSelector, SelectionKey.OP_READ);
            channel.register(writeSelector, SelectionKey.OP_WRITE);
            return new JsonLineConnection(
                channel,
                readSelector,
                writeSelector,
                positive(maxRequestBytes, "maxRequestBytes"),
                positive(maxResponseBytes, "maxResponseBytes"),
                positive(maxJsonDepth, "maxJsonDepth")
            );
        } catch (IOException | RuntimeException error) {
            closeQuietly(readSelector);
            closeQuietly(writeSelector);
            closeQuietly(channel);
            throw new CmuxTransportException("cannot connect to session socket " + socket, error);
        }
    }

    void send(Map<String, Object> value, Deadline deadline) throws CmuxException {
        Objects.requireNonNull(deadline, "deadline");
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
                writeFully(ByteBuffer.wrap(message), deadline);
                writeFully(ByteBuffer.wrap(new byte[] {'\n'}), deadline);
            } catch (CmuxException error) {
                close();
                throw error;
            } catch (ClosedChannelException error) {
                close();
                throw new CmuxTransportException("connection is closed", error);
            } catch (IOException error) {
                close();
                throw new CmuxTransportException("socket write failed", error);
            }
        }
    }

    Map<String, Object> receive(Duration timeout) throws CmuxException {
        return receive(deadline(timeout), () -> {});
    }

    Map<String, Object> receive(Duration timeout, Runnable beforeWait)
        throws CmuxException {
        return receive(deadline(timeout), beforeWait);
    }

    Map<String, Object> receive(Deadline deadline) throws CmuxException {
        return receive(deadline, () -> {});
    }

    Map<String, Object> receive(Deadline deadline, Runnable beforeWait)
        throws CmuxException {
        Objects.requireNonNull(deadline, "deadline");
        Objects.requireNonNull(beforeWait, "beforeWait");
        synchronized (readLock) {
            ensureOpen();
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
                long remaining = deadline.remainingNanos(
                    "session did not respond before timeout"
                );
                try {
                    beforeWait.run();
                    int ready = readSelector.select(
                        Math.max(1, Duration.ofNanos(remaining).toMillis())
                    );
                    if (closed.get()) {
                        throw new CmuxTransportException("connection is closed");
                    }
                    if (ready == 0) {
                        continue;
                    }
                    readSelector.selectedKeys().clear();
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

    private void writeFully(ByteBuffer bytes, Deadline deadline)
        throws IOException, CmuxException {
        while (bytes.hasRemaining()) {
            deadline.remainingNanos("session did not accept request before timeout");
            int written = channel.write(bytes);
            if (written > 0) {
                continue;
            }
            if (closed.get()) {
                throw new ClosedChannelException();
            }
            if (Thread.currentThread().isInterrupted()) {
                throw interruptedWrite();
            }
            try {
                long remaining = deadline.remainingNanos(
                    "session did not accept request before timeout"
                );
                int ready = writeSelector.select(
                    Math.max(1, Duration.ofNanos(remaining).toMillis())
                );
                if (closed.get()) {
                    throw new ClosedChannelException();
                }
                if (Thread.currentThread().isInterrupted()) {
                    throw interruptedWrite();
                }
                if (ready > 0) {
                    writeSelector.selectedKeys().clear();
                }
            } catch (ClosedSelectorException | CancelledKeyException error) {
                ClosedChannelException closedChannel = new ClosedChannelException();
                closedChannel.initCause(error);
                throw closedChannel;
            }
        }
    }

    private static CmuxTransportException interruptedWrite() {
        InterruptedException error = new InterruptedException("socket write interrupted");
        Thread.currentThread().interrupt();
        return new CmuxTransportException("interrupted during socket write", error);
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

    static Deadline deadline(Duration timeout) {
        if (timeout == null || timeout.isNegative() || timeout.isZero()) {
            throw new IllegalArgumentException("timeout must be positive");
        }
        long now = System.nanoTime();
        long nanos;
        try {
            nanos = timeout.toNanos();
        } catch (ArithmeticException error) {
            return Deadline.infinite();
        }
        return now > Long.MAX_VALUE - nanos
            ? Deadline.infinite()
            : new Deadline(now + nanos, false);
    }

    static final class Deadline {
        private final long nanoTime;
        private final boolean infinite;

        private Deadline(long nanoTime, boolean infinite) {
            this.nanoTime = nanoTime;
            this.infinite = infinite;
        }

        private static Deadline infinite() {
            return new Deadline(0, true);
        }

        private long remainingNanos(String timeoutMessage)
            throws CmuxTimeoutException {
            if (infinite) {
                return Long.MAX_VALUE;
            }
            long remaining = nanoTime - System.nanoTime();
            if (remaining <= 0) {
                throw new CmuxTimeoutException(timeoutMessage);
            }
            return remaining;
        }
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
        readSelector.wakeup();
        writeSelector.wakeup();
        closeQuietly(channel);
        closeQuietly(readSelector);
        closeQuietly(writeSelector);
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
