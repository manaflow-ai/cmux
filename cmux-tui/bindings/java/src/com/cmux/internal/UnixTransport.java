package com.cmux.internal;

import com.cmux.ProtocolError;
import com.cmux.Transport;
import com.cmux.raw.Json;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.ByteChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;

/** Bounded JSON-lines transport using Java 17 Unix-domain sockets. */
public final class UnixTransport implements Transport {
    static final int READ_BUFFER_BYTES = 8192;

    private final ByteChannel channel;
    private final int maxRequestBytes;
    private final int maxResponseBytes;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final Object readLock = new Object();
    private final Object writeLock = new Object();
    private final ByteBuffer readBuffer = ByteBuffer.allocate(READ_BUFFER_BYTES);
    private final ByteArrayOutputStream frame =
        new ByteArrayOutputStream(READ_BUFFER_BYTES);

    public UnixTransport(Path socket, int maxRequestBytes, int maxResponseBytes)
            throws IOException {
        this.maxRequestBytes = positive(maxRequestBytes, "maxRequestBytes");
        this.maxResponseBytes = positive(maxResponseBytes, "maxResponseBytes");
        SocketChannel opened = SocketChannel.open(StandardProtocolFamily.UNIX);
        try {
            opened.connect(UnixDomainSocketAddress.of(socket));
        } catch (IOException | RuntimeException error) {
            try {
                opened.close();
            } catch (IOException closeError) {
                error.addSuppressed(closeError);
            }
            throw error;
        }
        channel = opened;
        readBuffer.limit(0);
    }

    UnixTransport(ByteChannel channel, int maxRequestBytes, int maxResponseBytes) {
        this.channel = Objects.requireNonNull(channel, "channel");
        this.maxRequestBytes = positive(maxRequestBytes, "maxRequestBytes");
        this.maxResponseBytes = positive(maxResponseBytes, "maxResponseBytes");
        readBuffer.limit(0);
    }

    @Override
    public void send(Map<String, Object> message) throws IOException {
        byte[] encoded = (Json.stringify(Wire.encode(message)) + "\n")
            .getBytes(StandardCharsets.UTF_8);
        if (encoded.length - 1 > maxRequestBytes) {
            throw new ProtocolError("request exceeds " + maxRequestBytes + " bytes");
        }
        synchronized (writeLock) {
            ensureOpen();
            ByteBuffer buffer = ByteBuffer.wrap(encoded);
            while (buffer.hasRemaining()) {
                channel.write(buffer);
            }
        }
    }

    @Override
    public Map<String, Object> receive() throws IOException {
        synchronized (readLock) {
            ensureOpen();
            while (true) {
                while (readBuffer.hasRemaining()) {
                    byte value = readBuffer.get();
                    if (value == '\n') {
                        return decodeFrame();
                    }
                    if (frame.size() >= maxResponseBytes) {
                        close();
                        throw new ProtocolError(
                            "server message exceeds " + maxResponseBytes + " bytes"
                        );
                    }
                    frame.write(value);
                }

                readBuffer.clear();
                int count = channel.read(readBuffer);
                if (count < 0) {
                    throw new IOException("session socket closed");
                }
                readBuffer.flip();
                if (count == 0) {
                    continue;
                }
            }
        }
    }

    @Override
    public void close() throws IOException {
        if (closed.compareAndSet(false, true)) {
            channel.close();
        }
    }

    private void ensureOpen() throws IOException {
        if (closed.get()) {
            throw new IOException("transport is closed");
        }
    }

    private Map<String, Object> decodeFrame() {
        byte[] encoded = frame.toByteArray();
        frame.reset();
        int length = encoded.length;
        if (length > 0 && encoded[length - 1] == '\r') {
            length--;
        }
        if (length != encoded.length) {
            byte[] trimmed = new byte[length];
            System.arraycopy(encoded, 0, trimmed, 0, length);
            encoded = trimmed;
        }
        return Wire.object(
            Json.parse(encoded, Json.DEFAULT_MAX_DEPTH),
            "server message"
        );
    }

    private static int positive(int value, String name) {
        if (value < 1) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return value;
    }
}
