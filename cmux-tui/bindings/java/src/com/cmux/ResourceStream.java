package com.cmux;

import java.time.Duration;
import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/** Typed, cancellable protocol stream. Streams, unlike resource handles, are closeable. */
public final class ResourceStream<T> implements AutoCloseable {
    private final Client client;
    private final Ids.StreamId id;
    private final String attachmentLease;
    private final Client.StreamRoute route;
    private final Client.Decoder<T> decoder;
    private final AtomicBoolean finished = new AtomicBoolean();
    private final AtomicBoolean cancellationStarted = new AtomicBoolean();
    private final CompletableFuture<Void> cancellation = new CompletableFuture<>();
    private final AtomicReference<StreamEndError> end = new AtomicReference<>();

    ResourceStream(
        Client client,
        Ids.StreamId id,
        String attachmentLease,
        Client.StreamRoute route,
        Client.Decoder<T> decoder
    ) {
        this.client = client;
        this.id = id;
        this.attachmentLease = attachmentLease;
        this.route = route;
        this.decoder = decoder;
    }

    public Ids.StreamId id() {
        return id;
    }

    /** Lease required to size or release a terminal/browser attachment. */
    public Optional<String> attachmentLease() {
        return Optional.ofNullable(attachmentLease);
    }

    public StreamItem<T> next() {
        return next(client.timeout());
    }

    public StreamItem<T> next(Duration timeout) {
        return receive(timeout, false).orElseThrow();
    }

    /**
     * Waits at most {@code timeout} for one item.
     *
     * <p>An empty result means the bound elapsed without consuming or ending
     * the stream. A terminal stream envelope still throws {@link
     * StreamEndError} and remains available through {@link #end()}.</p>
     */
    public Optional<StreamItem<T>> poll(Duration timeout) {
        return receive(timeout, true);
    }

    private Optional<StreamItem<T>> receive(
        Duration timeout,
        boolean timeoutIsEmpty
    ) {
        Objects.requireNonNull(timeout, "timeout");
        if (timeout.isNegative() || timeout.isZero()) {
            throw new IllegalArgumentException("timeout must be positive");
        }
        if (finished.get()) {
            throw new TransportError("stream is closed");
        }
        Client.StreamMessage message;
        try {
            long millis = Math.max(1L, timeout.toMillis());
            message = route.poll(millis, TimeUnit.MILLISECONDS);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new TransportError("interrupted while waiting for stream item", error);
        }
        if (message == null) {
            if (timeoutIsEmpty) {
                return Optional.empty();
            }
            throw new TransportError("stream did not produce an item before timeout");
        }
        if (message.error() != null) {
            finished.set(true);
            if (message.error() instanceof StreamEndError terminal) {
                end.set(terminal);
            }
            throw message.error();
        }
        if ("stream_end".equals(message.envelope().get("type"))) {
            finished.set(true);
            StreamEndError terminal = Client.decodeStreamEnd(message.envelope());
            end.set(terminal);
            throw terminal;
        }
        Client.validateStreamItemEnvelope(message.envelope());
        Ids.StreamId returned = new Ids.StreamId(
            com.cmux.internal.Wire.string(
                message.envelope().get("stream_id"),
                "stream item stream_id"
            )
        );
        if (!returned.equals(id)) {
            throw new ProtocolError(
                "stream item returned a different stream_id"
            );
        }
        Decimal sequence = WireAccess.decimal(message.envelope().get("sequence"), "sequence");
        boolean cursorPresent = message.envelope().containsKey("cursor");
        if (cursorPresent && message.envelope().get("cursor") == null) {
            throw new ProtocolError("stream item cursor must not be null");
        }
        Cursor cursor = cursorPresent
            ? Client.decodeCursor(message.envelope().get("cursor"))
            : null;
        T value = decoder.decode(message.envelope().get("item"), cursor);
        return Optional.of(new StreamItem<>(
            sequence,
            Optional.ofNullable(cursor),
            value
        ));
    }

    @Override
    public void close() {
        if (!cancellationStarted.compareAndSet(false, true)) {
            awaitCancellation();
            return;
        }
        if (!finished.compareAndSet(false, true)) {
            cancellation.complete(null);
            return;
        }
        try {
            client.cancelStream(id, route).ifPresent(end::set);
            cancellation.complete(null);
        } catch (RuntimeException failure) {
            cancellation.completeExceptionally(failure);
            throw failure;
        }
    }

    /** Returns the observed server terminal envelope after next or close. */
    public Optional<StreamEndError> end() {
        return Optional.ofNullable(end.get());
    }

    private void awaitCancellation() {
        try {
            cancellation.join();
        } catch (CompletionException completed) {
            if (completed.getCause() instanceof RuntimeException failure) {
                throw failure;
            }
            throw completed;
        }
    }

    /** Avoid exposing the internal wire package from a public generic signature. */
    private static final class WireAccess {
        private WireAccess() {}
        static Decimal decimal(Object value, String context) {
            return com.cmux.internal.Wire.decimal(value, context);
        }
    }
}
