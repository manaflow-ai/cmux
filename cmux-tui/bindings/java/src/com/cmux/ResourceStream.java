package com.cmux;

import java.time.Duration;
import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/** Typed, cancellable protocol stream. Streams, unlike resource handles, are closeable. */
public final class ResourceStream<T> implements AutoCloseable {
    private final Client client;
    private final Ids.StreamId id;
    private final Client.StreamRoute route;
    private final Client.Decoder<T> decoder;
    private final AtomicBoolean finished = new AtomicBoolean();
    private final AtomicReference<StreamEndError> end = new AtomicReference<>();

    ResourceStream(
        Client client,
        Ids.StreamId id,
        Client.StreamRoute route,
        Client.Decoder<T> decoder
    ) {
        this.client = client;
        this.id = id;
        this.route = route;
        this.decoder = decoder;
    }

    public Ids.StreamId id() {
        return id;
    }

    public StreamItem<T> next() {
        return next(client.timeout());
    }

    public StreamItem<T> next(Duration timeout) {
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
        Decimal sequence = WireAccess.decimal(message.envelope().get("sequence"), "sequence");
        Cursor cursor = Client.decodeCursor(message.envelope().get("cursor"));
        T value = decoder.decode(message.envelope().get("item"));
        return new StreamItem<>(sequence, java.util.Optional.ofNullable(cursor), value);
    }

    @Override
    public void close() {
        if (!finished.compareAndSet(false, true)) {
            return;
        }
        client.cancelStream(id, route).ifPresent(end::set);
    }

    /** Returns the observed server terminal envelope after next or close. */
    public Optional<StreamEndError> end() {
        return Optional.ofNullable(end.get());
    }

    /** Avoid exposing the internal wire package from a public generic signature. */
    private static final class WireAccess {
        private WireAccess() {}
        static Decimal decimal(Object value, String context) {
            return com.cmux.internal.Wire.decimal(value, context);
        }
    }
}
