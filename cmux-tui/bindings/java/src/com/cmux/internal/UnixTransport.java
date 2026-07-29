package com.cmux.internal;

import com.cmux.ProtocolError;
import com.cmux.Transport;
import com.cmux.raw.Json;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/** Bounded JSON-lines transport using Java 17 Unix-domain sockets. */
public final class UnixTransport implements Transport {
    private final SocketChannel channel;
    private final int maxRequestBytes;
    private final int maxResponseBytes;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final Object readLock = new Object();
    private final Object writeLock = new Object();

    public UnixTransport(Path socket, int maxRequestBytes, int maxResponseBytes)
            throws IOException {
        this.maxRequestBytes = positive(maxRequestBytes, "maxRequestBytes");
        this.maxResponseBytes = positive(maxResponseBytes, "maxResponseBytes");
        channel = SocketChannel.open(StandardProtocolFamily.UNIX);
        channel.connect(UnixDomainSocketAddress.of(socket));
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
            ByteArrayOutputStream line = new ByteArrayOutputStream(8192);
            ByteBuffer one = ByteBuffer.allocate(1);
            while (true) {
                one.clear();
                int count = channel.read(one);
                if (count < 0) {
                    throw new IOException("session socket closed");
                }
                if (count == 0) {
                    continue;
                }
                byte value = one.array()[0];
                if (value == '\n') {
                    break;
                }
                if (line.size() >= maxResponseBytes) {
                    close();
                    throw new ProtocolError(
                        "server message exceeds " + maxResponseBytes + " bytes"
                    );
                }
                line.write(value);
            }
            byte[] encoded = line.toByteArray();
            int length = encoded.length;
            if (length > 0 && encoded[length - 1] == '\r') {
                length--;
            }
            Object decoded = Json.parse(
                new String(encoded, 0, length, StandardCharsets.UTF_8)
            );
            return Wire.object(decoded, "server message");
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

    private static int positive(int value, String name) {
        if (value < 1) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return value;
    }
}
