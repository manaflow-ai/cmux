package com.cmux.internal;

import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.SocketTimeoutException;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.ClosedByInterruptException;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Objects;

/** Internal Unix-domain connector shared by the resource and raw clients. */
public final class UnixSocketConnector {
    private UnixSocketConnector() {}

    /** Opens a blocking Unix-domain channel without an initial deadline. */
    public static SocketChannel open(Path socket) throws IOException {
        return open(socket, null);
    }

    /**
     * Opens a blocking Unix-domain channel with a bounded initial connection.
     *
     * <p>The channel uses a non-blocking connect and a timed selector while
     * establishing the link, then is returned in blocking mode for the
     * resource transport. A null timeout is accepted for the legacy,
     * unbounded path used by the compatibility overload.
     */
    public static SocketChannel open(Path socket, Duration timeout)
            throws IOException {
        Objects.requireNonNull(socket, "socket");
        if (timeout != null) {
            positive(timeout, "timeout");
        }

        SocketChannel opened = SocketChannel.open(StandardProtocolFamily.UNIX);
        Selector selector = null;
        try {
            UnixDomainSocketAddress address = UnixDomainSocketAddress.of(socket);
            if (timeout == null) {
                opened.connect(address);
                return opened;
            }

            long started = System.nanoTime();
            checkInterrupted();
            opened.configureBlocking(false);
            if (!opened.connect(address)) {
                selector = Selector.open();
                opened.register(selector, SelectionKey.OP_CONNECT);
                long timeoutNanos = timeoutNanos(timeout);
                while (!opened.finishConnect()) {
                    checkInterrupted();
                    long remaining = timeoutNanos - (System.nanoTime() - started);
                    if (remaining <= 0) {
                        throw connectTimeout(timeout);
                    }
                    selector.select(selectMillis(remaining));
                    checkInterrupted();
                    selector.selectedKeys().clear();
                }
                if (timeoutNanos != Long.MAX_VALUE
                        && System.nanoTime() - started >= timeoutNanos) {
                    throw connectTimeout(timeout);
                }
            }
            opened.configureBlocking(true);
            return opened;
        } catch (IOException | RuntimeException error) {
            closeQuietly(selector, error);
            closeQuietly(opened, error);
            throw error;
        } finally {
            closeQuietly(selector, null);
        }
    }

    private static long timeoutNanos(Duration timeout) {
        try {
            return timeout.toNanos();
        } catch (ArithmeticException overflow) {
            return Long.MAX_VALUE;
        }
    }

    private static long selectMillis(long nanos) {
        long millis = nanos / 1_000_000L;
        if (nanos % 1_000_000L != 0) {
            millis++;
        }
        return Math.max(1L, millis);
    }

    private static SocketTimeoutException connectTimeout(Duration timeout) {
        return new SocketTimeoutException(
            "Unix socket connect timed out after " + timeout
        );
    }

    private static void checkInterrupted() throws ClosedByInterruptException {
        if (Thread.interrupted()) {
            Thread.currentThread().interrupt();
            throw new ClosedByInterruptException();
        }
    }

    private static Duration positive(Duration value, String name) {
        if (value.isNegative() || value.isZero()) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return value;
    }

    private static void closeQuietly(AutoCloseable closeable, Throwable error) {
        if (closeable == null) {
            return;
        }
        try {
            closeable.close();
        } catch (Exception closeError) {
            if (error != null) {
                error.addSuppressed(closeError);
            }
        }
    }
}
