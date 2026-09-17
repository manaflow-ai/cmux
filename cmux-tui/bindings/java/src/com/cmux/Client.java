package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.UnixTransport;
import com.cmux.internal.Wire;
import com.cmux.raw.SocketDiscovery;
import java.io.IOException;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.Supplier;

/** Dependency-free Java 17 resource API client. */
public final class Client implements AutoCloseable {
    public static final int MAX_REQUEST_BYTES = 4 * 1024 * 1024;
    public static final int MAX_RESPONSE_BYTES = 16 * 1024 * 1024;
    public static final int MAX_STREAM_MESSAGES = 256;
    public static final int MAX_STREAM_BYTES = 16 * 1024 * 1024;
    private static final HexFormat LOWERCASE_HEX = HexFormat.of();
    private static final Duration FAILED_STREAM_OPEN_CLEANUP_TIMEOUT =
        Duration.ofSeconds(1);
    private static final Duration ABANDONED_REQUEST_CLEANUP_TIMEOUT =
        Duration.ofSeconds(1);
    static final int FAILED_STREAM_OPEN_CLEANUP_QUEUE_CAPACITY = 8;

    @FunctionalInterface
    interface Decoder<T> {
        T decode(Object value, Cursor envelopeCursor);
    }

    @FunctionalInterface
    interface ValueDecoder<T> {
        T decode(Object value);
    }

    record StreamMessage(Map<String, Object> envelope, RuntimeException error, int size) {}

    static final class AbandonedRequestCleanup {
        private final AtomicBoolean claimed = new AtomicBoolean();
        private final CompletableFuture<RuntimeException> outcome =
            new CompletableFuture<>();
    }

    static final class InterruptTracker {
        private boolean interrupted;
    }

    static final class StreamRoute {
        private final ArrayBlockingQueue<StreamMessage> messages =
            new ArrayBlockingQueue<>(MAX_STREAM_MESSAGES + 1);
        private final Map<String, Object> cancelParams;
        private final Decoder<?> decoder;
        private int queuedBytes;
        private boolean accepting = true;
        private boolean terminated;
        private boolean endDelivered;
        private boolean openDispatched;
        private boolean openAcknowledged;
        private boolean cleanupStarted;

        StreamRoute(
            Map<String, Object> cancelParams,
            Decoder<?> decoder
        ) {
            this.cancelParams = Map.copyOf(cancelParams);
            this.decoder = Objects.requireNonNull(decoder, "decoder");
        }

        synchronized boolean deliver(StreamMessage message) {
            if (!accepting || terminated) {
                return false;
            }
            boolean end = "stream_end".equals(message.envelope().get("type"));
            if (!end && (messages.size() >= MAX_STREAM_MESSAGES ||
                    queuedBytes + message.size() > MAX_STREAM_BYTES)) {
                return false;
            }
            if (end) {
                accepting = false;
            }
            if (!messages.offer(message)) {
                return false;
            }
            if (end) {
                endDelivered = true;
            }
            queuedBytes += message.size();
            return true;
        }

        synchronized void finish(RuntimeException error) {
            if (terminated) {
                return;
            }
            accepting = false;
            terminated = true;
            messages.clear();
            queuedBytes = 0;
            messages.offer(new StreamMessage(Map.of(), error, 0));
        }

        synchronized void overflow() {
            finish(new StreamEndError(
                "gap",
                Optional.empty(),
                Optional.of(new ResourceError(
                    "stream.local_overflow",
                    "local stream queue exceeded its bounded capacity",
                    Map.of(
                        "message_limit", MAX_STREAM_MESSAGES,
                        "byte_limit", MAX_STREAM_BYTES
                    ),
                    true
                )),
                Optional.of("open a fresh stream to receive a new snapshot")
            ));
        }

        synchronized Optional<StreamEndError> cancelTerminal() {
            accepting = false;
            terminated = true;
            StreamEndError end = null;
            StreamMessage message;
            while ((message = messages.poll()) != null) {
                if ("stream_end".equals(message.envelope().get("type"))) {
                    end = decodeStreamEnd(message.envelope());
                } else if (message.error() instanceof StreamEndError candidate) {
                    end = candidate;
                }
            }
            queuedBytes = 0;
            return Optional.ofNullable(end);
        }

        synchronized void cancellationConfirmed() {
            accepting = false;
            terminated = true;
            messages.clear();
            queuedBytes = 0;
        }

        StreamMessage poll(long timeout, TimeUnit unit) throws InterruptedException {
            StreamMessage message = messages.poll(timeout, unit);
            if (message != null) {
                synchronized (this) {
                    queuedBytes = Math.max(0, queuedBytes - message.size());
                }
            }
            return message;
        }

        synchronized void markOpenDispatched() {
            openDispatched = true;
        }

        synchronized void markOpenAcknowledged() {
            openAcknowledged = true;
        }

        synchronized Optional<Map<String, Object>> failedOpenCancelParams() {
            if (!openDispatched || openAcknowledged || cleanupStarted) {
                return Optional.empty();
            }
            cleanupStarted = true;
            return Optional.of(cancelParams);
        }

        synchronized boolean abandonFailedOpen(RuntimeException error) {
            boolean cleanupNeeded =
                openDispatched && !openAcknowledged && !cleanupStarted;
            if (cleanupNeeded) {
                cleanupStarted = true;
            }
            finish(error);
            return cleanupNeeded;
        }

        synchronized boolean beginStreamCleanup() {
            if (cleanupStarted || endDelivered) {
                return false;
            }
            cleanupStarted = true;
            return true;
        }

        synchronized boolean cleanupInProgress() {
            return cleanupStarted;
        }

        synchronized boolean endDelivered() {
            return endDelivered;
        }

        void validatePayload(Map<String, Object> envelope) {
            Cursor cursor = envelope.containsKey(Wire.CURSOR)
                ? decodeCursor(envelope.get(Wire.CURSOR))
                : null;
            try {
                decoder.decode(envelope.get("item"), cursor);
            } catch (IllegalArgumentException invalidPayload) {
                throw new ProtocolError(
                    "stream item payload is malformed",
                    invalidPayload
                );
            }
        }
    }

    private final Transport transport;
    private final Duration timeout;
    private final Supplier<String> idempotencyKeys;
    private final Supplier<String> streamIds;
    private final AtomicLong nextRequest = new AtomicLong();
    private final AtomicBoolean closed = new AtomicBoolean();
    private final ConcurrentHashMap<String, CompletableFuture<Object>> pending =
        new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Ids.StreamId, StreamRoute> streams =
        new ConcurrentHashMap<>();
    private final ReentrantLock writeLock = new ReentrantLock();
    private final Condition failedOpenCleanupFinished =
        writeLock.newCondition();
    private final Object requestCleanupMonitor = new Object();
    private int requestCleanups;
    private CompletableFuture<Void> requestCleanupFinished =
        CompletableFuture.completedFuture(null);
    private final ThreadPoolExecutor cleanupExecutor =
        newCleanupExecutor();
    private final ScheduledThreadPoolExecutor deadlineExecutor =
        newDeadlineExecutor();
    private final Thread reader;
    private int failedOpenCleanups;
    private volatile boolean framingUnsafe;
    private volatile RuntimeException connectionError;

    private Client(Builder builder) {
        timeout = positive(builder.timeout, "timeout");
        idempotencyKeys = builder.idempotencyKeys == null
            ? randomSource("idem_")
            : builder.idempotencyKeys;
        streamIds = builder.streamIds == null
            ? randomSource("stream_")
            : builder.streamIds;
        if (builder.transport != null) {
            transport = builder.transport;
        } else {
            Path socket = SocketDiscovery.resolve(builder.socket, builder.session);
            Transport openedTransport;
            try {
                openedTransport = new UnixTransport(
                    socket,
                    builder.maxRequestBytes,
                    builder.maxResponseBytes,
                    timeout
                );
            } catch (IOException | UnsupportedOperationException error) {
                Path fallback = SocketDiscovery.legacyRawFallback(socket, builder.session);
                if (fallback != null) {
                    try {
                        openedTransport = new UnixTransport(
                            fallback,
                            builder.maxRequestBytes,
                            builder.maxResponseBytes,
                            timeout
                        );
                    } catch (IOException | UnsupportedOperationException fallbackError) {
                        fallbackError.addSuppressed(error);
                        throw new TransportError(
                            "cannot connect to Unix session socket " + socket +
                                " or legacy fallback " + fallback,
                            fallbackError
                        );
                    }
                } else {
                    throw new TransportError(
                        "cannot connect to Unix session socket " + socket +
                            "; inject a Transport on platforms without Unix-domain sockets",
                        error
                    );
                }
            }
            transport = openedTransport;
        }
        reader = new Thread(this::readLoop, "cmux-resource-api-reader");
        reader.setDaemon(true);
        reader.start();
    }

    public static Builder builder() {
        return new Builder();
    }

    public Duration timeout() {
        return timeout;
    }

    public Machine machine(Selector<Ids.MachineId> selector) {
        return new Machine(this, selector);
    }

    public List<Machine> listMachines(Options.Read options) {
        Object result = requestValue(
            Operations.MACHINE_LIST,
            copy(options == null ? Map.of() : options.extra()),
            null
        );
        List<Object> values = listPayload(result, "machines");
        List<Machine> machines = new ArrayList<>(values.size());
        for (Object value : values) {
            Snapshots.MachineSnapshot snapshot = decodeMachine(value);
            machines.add(new Machine(this, Selector.id(snapshot.id()), snapshot));
        }
        return List.copyOf(machines);
    }

    public List<Machine> findMachinesByName(String name) {
        Objects.requireNonNull(name, "name");
        return listMachines(Options.Read.defaults()).stream()
            .filter(machine -> machine.cached()
                .map(Snapshots.MachineSnapshot::name)
                .map(name::equals)
                .orElse(false))
            .toList();
    }

    Map<String, Object> request(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation mutation
    ) {
        return Wire.object(
            requestValue(operation, params, mutation),
            operation.wireName() + " result"
        );
    }

    Object requestValue(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation mutation
    ) {
        return requestValue(operation, params, mutation, timeout, null);
    }

    private Object requestValue(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation mutation,
        Duration waitTimeout,
        Runnable onDispatched
    ) {
        return requestValueUntil(
            operation,
            params,
            mutation,
            System.nanoTime() + waitTimeout.toNanos(),
            onDispatched
        );
    }

    private Object requestValueUntil(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation mutation,
        long deadline,
        Runnable onDispatched
    ) {
        ensureOpen();
        boolean isMutation = operation.operationClass() == Operations.Class.MUTATION;
        if (isMutation != (mutation != null)) {
            throw new IllegalArgumentException(
                operation.wireName() + (isMutation
                    ? " requires mutation options"
                    : " forbids mutation options")
            );
        }
        String requestId = "java-" + nextRequest.incrementAndGet();
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("protocol", Wire.PROTOCOL);
        envelope.put("type", "request");
        envelope.put("id", requestId);
        envelope.put("operation", operation.wireName());
        Map<String, Object> encodedParams = copy(params);
        String mutationKey = null;
        if (mutation != null) {
            mutation.expectedRevision().ifPresent(
                revision -> encodedParams.put("expected_revision", revision)
            );
        }
        envelope.put("params", Wire.encode(encodedParams));
        if (mutation != null) {
            mutationKey = Options.validateIdempotencyKey(
                mutation.idempotencyKey().orElseGet(idempotencyKeys)
            );
            envelope.put(Wire.IDEMPOTENCY_KEY, mutationKey);
        }
        CompletableFuture<Object> future = new CompletableFuture<>();
        AbandonedRequestCleanup cleanup = isCancelableWait(operation)
            ? new AbandonedRequestCleanup()
            : null;
        pending.put(requestId, future);
        if (closed.get()) {
            pending.remove(requestId, future);
            throw closedError();
        }
        boolean transportSendStarted = false;
        boolean transportDispatched = false;
        try {
            lockForRequest(deadline, operation.wireName());
            try {
                ensureOpen();
                transportSendStarted = true;
                sendWithDeadline(envelope, operation.wireName(), deadline);
                transportDispatched = true;
                if (onDispatched != null) {
                    onDispatched.run();
                }
            } finally {
                writeLock.unlock();
            }
        } catch (IOException | RuntimeException error) {
            pending.remove(requestId);
            RuntimeException failure = transportError(
                "cannot send " + operation.wireName(),
                error
            );
            if (transportSendStarted) {
                // Transport does not expose a byte count. Conservatively close
                // after any send exception because the wire may contain a
                // partial JSON frame. Pre-close cancellation would append to
                // that malformed frame, so disconnect without cleanup.
                fail(failure, false);
            }
            throw uncertain(operation, mutationKey, failure);
        }
        try {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0L) {
                throw new TimeoutException(
                    operation.wireName() + " timed out"
                );
            }
            return future.get(
                remaining,
                TimeUnit.NANOSECONDS
            );
        } catch (InterruptedException error) {
            RuntimeException original = uncertain(
                operation,
                mutationKey,
                new TransportError(
                    "interrupted while waiting for " + operation.wireName(),
                    error
                )
            );
            if (cleanup != null && transportDispatched) {
                cleanupAbandonedRequest(
                    cleanup,
                    operation,
                    requestId,
                    future
                );
            } else {
                pending.remove(requestId, future);
            }
            Thread.currentThread().interrupt();
            throw original;
        } catch (TimeoutException error) {
            RuntimeException original = uncertain(
                operation,
                mutationKey,
                new TransportError(operation.wireName() + " timed out", error)
            );
            if (cleanup != null && transportDispatched) {
                cleanupAbandonedRequest(
                    cleanup,
                    operation,
                    requestId,
                    future
                );
            } else {
                pending.remove(requestId, future);
            }
            throw original;
        } catch (ExecutionException error) {
            Throwable cause = error.getCause();
            if (cause instanceof RuntimeException runtime) {
                if (runtime instanceof TransportError) {
                    throw uncertain(operation, mutationKey, runtime);
                }
                throw runtime;
            }
            throw new TransportError(operation.wireName() + " failed", cause);
        }
    }

    private static boolean isCancelableWait(Operations operation) {
        return operation == Operations.TERMINAL_WAIT ||
            operation == Operations.TERMINAL_WAIT_EXIT;
    }

    private RuntimeException cleanupAbandonedRequest(
        AbandonedRequestCleanup cleanup,
        Operations operation,
        String targetId,
        CompletableFuture<Object> targetResponse
    ) {
        if (!cleanup.claimed.compareAndSet(false, true)) {
            return cleanup.outcome.join();
        }

        long deadline = System.nanoTime() +
            ABANDONED_REQUEST_CLEANUP_TIMEOUT.toNanos();
        InterruptTracker interrupts = new InterruptTracker();
        RuntimeException failure = null;
        boolean locked = false;
        String cancelId = null;
        CompletableFuture<Object> cancelResponse = null;
        beginRequestCleanup();
        try {
            if (!acquireCleanupWriteLock(deadline, interrupts)) {
                throw abandonedRequestCleanupTimeout();
            }
            locked = true;
            ensureOpen();
            if (framingUnsafe) {
                throw new TransportError(
                    "cannot cancel abandoned request on framing-unsafe transport"
                );
            }

            cancelId = "java-" + nextRequest.incrementAndGet();
            Map<String, Object> envelope = new LinkedHashMap<>();
            envelope.put("protocol", Wire.PROTOCOL);
            envelope.put("type", "request");
            envelope.put("id", cancelId);
            envelope.put("operation", Operations.REQUEST_CANCEL.wireName());
            envelope.put(
                "params",
                Wire.encode(Map.of("request_id", targetId))
            );
            cancelResponse = new CompletableFuture<>();
            pending.put(cancelId, cancelResponse);
            ensureOpen();
            sendWithDeadline(
                envelope,
                Operations.REQUEST_CANCEL.wireName(),
                deadline
            );

            Object cancelValue = awaitCleanupResponse(
                cancelResponse,
                deadline,
                interrupts
            );
            boolean canceled = decodeRequestCancelResult(cancelValue);
            if (canceled) {
                if (!pending.remove(targetId, targetResponse)) {
                    drainAbandonedWaitResponse(
                        operation,
                        targetResponse,
                        deadline,
                        interrupts
                    );
                    throw new ProtocolError(
                        "request.cancel returned canceled=true after the target responded"
                    );
                }
            } else {
                drainAbandonedWaitResponse(
                    operation,
                    targetResponse,
                    deadline,
                    interrupts
                );
            }
        } catch (TimeoutException error) {
            failure = new TransportError(
                "request cancellation cleanup timed out after " +
                    ABANDONED_REQUEST_CLEANUP_TIMEOUT,
                error
            );
        } catch (ExecutionException error) {
            Throwable cause = error.getCause();
            failure = transportError(
                "request cancellation cleanup failed",
                cause == null ? error : cause
            );
        } catch (IOException | RuntimeException error) {
            failure = transportError(
                "request cancellation cleanup failed",
                error
            );
        } finally {
            if (cancelId != null && cancelResponse != null) {
                pending.remove(cancelId, cancelResponse);
            }
            if (failure != null) {
                pending.remove(targetId, targetResponse);
                fail(failure, false);
            }
            if (locked) {
                writeLock.unlock();
            }
            finishRequestCleanup();
            cleanup.outcome.complete(failure);
            if (interrupts.interrupted) {
                Thread.currentThread().interrupt();
            }
        }
        return failure;
    }

    private boolean acquireCleanupWriteLock(
        long deadline,
        InterruptTracker interrupts
    ) {
        while (true) {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0L) {
                return false;
            }
            try {
                return writeLock.tryLock(
                    remaining,
                    TimeUnit.NANOSECONDS
                );
            } catch (InterruptedException error) {
                interrupts.interrupted = true;
            }
        }
    }

    private static Object awaitCleanupResponse(
        CompletableFuture<Object> response,
        long deadline,
        InterruptTracker interrupts
    ) throws TimeoutException, ExecutionException {
        while (true) {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0L) {
                throw new TimeoutException("cleanup response timed out");
            }
            try {
                return response.get(remaining, TimeUnit.NANOSECONDS);
            } catch (InterruptedException error) {
                interrupts.interrupted = true;
            }
        }
    }

    private static boolean decodeRequestCancelResult(Object value) {
        Map<String, Object> result = exactObject(
            value,
            "request cancel result",
            "canceled"
        );
        return Wire.bool(
            result.get("canceled"),
            "request cancel canceled"
        );
    }

    private static void drainAbandonedWaitResponse(
        Operations operation,
        CompletableFuture<Object> response,
        long deadline,
        InterruptTracker interrupts
    ) throws TimeoutException, ExecutionException {
        Object value;
        try {
            value = awaitCleanupResponse(response, deadline, interrupts);
        } catch (ExecutionException error) {
            if (error.getCause() instanceof ResourceError) {
                return;
            }
            throw error;
        }
        if (operation == Operations.TERMINAL_WAIT) {
            decodeTerminalWait(value);
            return;
        }
        if (operation == Operations.TERMINAL_WAIT_EXIT) {
            decodeTerminalWaitExit(value);
            return;
        }
        throw new ProtocolError(
            "request cancellation targeted unsupported operation " +
                operation.wireName()
        );
    }

    private void beginRequestCleanup() {
        synchronized (requestCleanupMonitor) {
            if (requestCleanups == 0) {
                requestCleanupFinished = new CompletableFuture<>();
            }
            requestCleanups++;
        }
    }

    private void finishRequestCleanup() {
        CompletableFuture<Void> finished = null;
        synchronized (requestCleanupMonitor) {
            if (requestCleanups > 0) {
                requestCleanups--;
            }
            if (requestCleanups == 0) {
                finished = requestCleanupFinished;
            }
        }
        if (finished != null) {
            finished.complete(null);
        }
    }

    private CompletableFuture<Void> activeRequestCleanup() {
        synchronized (requestCleanupMonitor) {
            return requestCleanups == 0
                ? null
                : requestCleanupFinished;
        }
    }

    private static TransportError abandonedRequestCleanupTimeout() {
        return new TransportError(
            "request cancellation cleanup timed out after " +
                ABANDONED_REQUEST_CLEANUP_TIMEOUT
        );
    }

    <T> ResourceStream<T> openStream(
        Operations operation,
        Map<String, Object> params,
        Decoder<T> decoder
    ) {
        Ids.StreamId streamId = new Ids.StreamId(streamIds.get());
        Map<String, Object> input = copy(params);
        Map<String, Object> cancelParams = Wire.map();
        for (String key : List.of(Wire.MACHINE, Wire.SESSION)) {
            if (input.containsKey(key)) {
                cancelParams.put(key, input.get(key));
            }
        }
        cancelParams.put("stream", streamId);
        StreamRoute route = new StreamRoute(cancelParams, decoder);
        streams.put(streamId, route);
        input.put(Wire.STREAM_ID, streamId);
        String attachmentLease = null;
        try {
            Object openedValue = requestValue(
                operation,
                input,
                null,
                timeout,
                () -> {
                    route.markOpenDispatched();
                }
            );
            try {
                Map<String, Object> opened = Wire.object(
                    openedValue,
                    operation.wireName() + " result"
                );
                boolean viewAttachment = operation == Operations.TERMINAL_ATTACH ||
                    operation == Operations.BROWSER_ATTACH;
                if (viewAttachment) {
                    requireExactFields(
                        opened,
                        operation.wireName() + " opened result",
                        Wire.STREAM_ID,
                        Wire.ATTACHMENT_LEASE
                    );
                    attachmentLease = Wire.string(
                        opened.get(Wire.ATTACHMENT_LEASE),
                        operation.wireName() + " attachment_lease"
                    );
                    if (attachmentLease.isEmpty() || attachmentLease.length() > 128) {
                        throw new ProtocolError(
                            operation.wireName() +
                                " attachment_lease must contain 1 to 128 characters"
                        );
                    }
                } else {
                    requireExactFields(
                        opened,
                        operation.wireName() + " opened result",
                        Wire.STREAM_ID,
                        Wire.CURSOR
                    );
                }
                Ids.StreamId returned = new Ids.StreamId(Wire.string(
                    opened.get(Wire.STREAM_ID),
                    operation.wireName() + " returned stream_id"
                ));
                if (!returned.equals(streamId)) {
                    throw new ProtocolError(
                        operation.wireName() + " returned a different stream_id"
                    );
                }
                if (!viewAttachment && opened.containsKey(Wire.CURSOR)) {
                    if (opened.get(Wire.CURSOR) == null) {
                        throw new ProtocolError(
                            operation.wireName() + " returned a null cursor"
                        );
                    }
                    decodeCursor(opened.get(Wire.CURSOR));
                }
            } catch (IllegalArgumentException invalidAcknowledgment) {
                throw new ProtocolError(
                    operation.wireName() +
                        " returned a malformed stream acknowledgment",
                    invalidAcknowledgment
                );
            }
            acknowledgeStreamOpen(route);
        } catch (RuntimeException error) {
            if (error instanceof ResourceError) {
                streams.remove(streamId, route);
                route.finish(error);
                throw error;
            }
            abandonFailedStreamOpen(
                streamId,
                route,
                error
            );
            throw error;
        }
        return new ResourceStream<>(this, streamId, attachmentLease, route, decoder);
    }

    private void abandonFailedStreamOpen(
        Ids.StreamId streamId,
        StreamRoute route,
        RuntimeException openError
    ) {
        if (!route.abandonFailedOpen(openError)) {
            streams.remove(streamId, route);
            return;
        }
        startBoundedFailedOpenCleanup(streamId, route);
    }

    private synchronized void acknowledgeStreamOpen(StreamRoute route) {
        ensureOpen();
        route.markOpenAcknowledged();
    }

    private void startBoundedFailedOpenCleanup(
        Ids.StreamId streamId,
        StreamRoute route
    ) {
        long deadline = System.nanoTime() +
            FAILED_STREAM_OPEN_CLEANUP_TIMEOUT.toNanos();
        boolean restoreInterrupt = Thread.interrupted();
        boolean gateActivated = false;
        try {
            while (!gateActivated) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0L) {
                    fail(
                        failedOpenCleanupTimeout(),
                        false
                    );
                    return;
                }
                boolean locked;
                try {
                    locked = writeLock.tryLock(
                        remaining,
                        TimeUnit.NANOSECONDS
                    );
                } catch (InterruptedException error) {
                    restoreInterrupt = true;
                    continue;
                }
                if (!locked) {
                    fail(failedOpenCleanupTimeout(), false);
                    return;
                }
                try {
                    if (closed.get()) {
                        return;
                    }
                    failedOpenCleanups++;
                    gateActivated = true;
                } finally {
                    writeLock.unlock();
                }
            }

            AtomicBoolean gateFinished = new AtomicBoolean();
            Runnable finishGate = () ->
                finishFailedOpenCleanupGate(gateFinished);
            Runnable cleanupAction = () -> {
                RuntimeException cleanupFailure = null;
                boolean locked = false;
                String requestId = null;
                CompletableFuture<Object> response = null;
                try {
                    if (!tryWriteLock(Duration.ofNanos(
                            Math.max(1L, deadline - System.nanoTime())
                        ))) {
                        cleanupFailure = failedOpenCleanupTimeout();
                        return;
                    }
                    locked = true;
                    if (closed.get()) {
                        return;
                    }
                    Map<String, Object> envelope =
                        streamCancelEnvelope(route.cancelParams);
                    requestId = String.valueOf(envelope.get("id"));
                    response = new CompletableFuture<>();
                    pending.put(requestId, response);
                    if (closed.get()) {
                        return;
                    }
                    sendWithDeadline(
                        envelope,
                        Operations.STREAM_CANCEL.wireName(),
                        deadline
                    );
                    writeLock.unlock();
                    locked = false;

                    Object result = response.get(
                        Math.max(1L, deadline - System.nanoTime()),
                        TimeUnit.NANOSECONDS
                    );
                    requireExactFields(
                        Wire.object(
                            result,
                            "failed stream-open cancellation result"
                        ),
                        "failed stream-open cancellation result"
                    );
                    streams.remove(streamId, route);
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    cleanupFailure = new TransportError(
                        "interrupted during failed stream-open cleanup",
                        error
                    );
                } catch (TimeoutException error) {
                    cleanupFailure = failedOpenCleanupTimeout();
                } catch (ExecutionException error) {
                    Throwable cause = error.getCause();
                    cleanupFailure = transportError(
                        "failed stream-open cleanup was rejected",
                        cause == null ? error : cause
                    );
                } catch (IOException | RuntimeException error) {
                    cleanupFailure = transportError(
                        "cannot send failed stream-open cleanup",
                        error
                    );
                } finally {
                    if (requestId != null && response != null) {
                        pending.remove(requestId, response);
                    }
                    if (cleanupFailure != null) {
                        streams.remove(streamId, route);
                        fail(cleanupFailure, false);
                    }
                    finishGate.run();
                    if (locked) {
                        writeLock.unlock();
                    }
                }
            };

            Future<?> cleanup;
            try {
                cleanup = cleanupExecutor.submit(cleanupAction);
            } catch (RejectedExecutionException rejected) {
                fail(
                    new TransportError(
                        "cannot schedule failed stream-open cleanup",
                        rejected
                    ),
                    false
                );
                return;
            }

            while (true) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0L) {
                    fail(failedOpenCleanupTimeout(), false);
                    cleanup.cancel(true);
                    return;
                }
                try {
                    cleanup.get(remaining, TimeUnit.NANOSECONDS);
                    return;
                } catch (InterruptedException error) {
                    restoreInterrupt = true;
                } catch (TimeoutException error) {
                    fail(failedOpenCleanupTimeout(), false);
                    cleanup.cancel(true);
                    return;
                } catch (CancellationException error) {
                    if (!closed.get()) {
                        fail(
                            new TransportError(
                                "failed stream-open cleanup was canceled",
                                error
                            ),
                            false
                        );
                    }
                    return;
                } catch (ExecutionException error) {
                    Throwable cause = error.getCause();
                    fail(
                        transportError(
                            "failed stream-open cleanup failed",
                            cause == null ? error : cause
                        ),
                        false
                    );
                    return;
                }
            }
        } finally {
            if (restoreInterrupt) {
                Thread.currentThread().interrupt();
            }
        }
    }

    Optional<StreamEndError> cancelStream(
        Ids.StreamId streamId,
        StreamRoute route
    ) {
        if (!route.beginStreamCleanup()) {
            streams.remove(streamId, route);
            return route.cancelTerminal();
        }
        long deadline = System.nanoTime() + timeout.toNanos();
        try {
            Map<String, Object> result = Wire.object(
                requestValueUntil(
                    Operations.STREAM_CANCEL,
                    route.cancelParams,
                    null,
                    deadline,
                    null
                ),
                "stream cancel result"
            );
            requireExactFields(result, "stream cancel result");
            StreamEndError terminal = awaitCanceledStreamEnd(
                streamId,
                route,
                deadline
            );
            route.cancellationConfirmed();
            return Optional.of(terminal);
        } catch (RuntimeException error) {
            fail(error);
            throw error;
        } finally {
            streams.remove(streamId, route);
        }
    }

    private StreamEndError awaitCanceledStreamEnd(
        Ids.StreamId streamId,
        StreamRoute route,
        long deadline
    ) {
        while (true) {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0L) {
                throw new TransportError(
                    "stream cancellation timed out waiting for stream_end"
                );
            }
            StreamMessage message;
            try {
                message = route.poll(remaining, TimeUnit.NANOSECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new TransportError(
                    "interrupted while waiting for canceled stream_end",
                    error
                );
            }
            if (message == null) {
                throw new TransportError(
                    "stream cancellation timed out waiting for stream_end"
                );
            }
            if (message.error() != null) {
                throw message.error();
            }
            if (!"stream_end".equals(message.envelope().get("type"))) {
                continue;
            }
            Ids.StreamId returned = new Ids.StreamId(
                Wire.string(
                    message.envelope().get(Wire.STREAM_ID),
                    "stream end stream_id"
                )
            );
            if (!returned.equals(streamId)) {
                throw new ProtocolError(
                    "stream cancellation returned a different stream_id"
                );
            }
            StreamEndError terminal = decodeStreamEnd(message.envelope());
            if (!terminal.reason().equals("canceled")) {
                throw new ProtocolError(
                    "stream cancellation ended with reason " +
                        terminal.reason()
                );
            }
            return terminal;
        }
    }

    @Override
    public void close() {
        if (!closed.compareAndSet(false, true)) {
            return;
        }
        try {
            transport.close();
        } catch (IOException error) {
            connectionError = new TransportError("cannot close transport", error);
        }
        fail(connectionError == null
            ? new TransportError("client is closed")
            : connectionError);
    }

    private void readLoop() {
        try {
            while (!closed.get()) {
                Map<String, Object> envelope = transport.receive();
                if (!Wire.PROTOCOL.equals(envelope.get("protocol"))) {
                    throw new ProtocolError("unexpected server protocol");
                }
                String type = Wire.string(envelope.get("type"), "envelope type");
                if ("response".equals(type)) {
                    deliverResponse(envelope);
                } else if ("stream_item".equals(type) || "stream_end".equals(type)) {
                    deliverStream(envelope);
                } else {
                    throw new ProtocolError("unexpected envelope type " + type);
                }
            }
        } catch (IOException | RuntimeException error) {
            if (!closed.get()) {
                fail(transportError("resource transport failed", error));
            }
        }
    }

    private void deliverResponse(Map<String, Object> envelope) {
        try {
            requireExactFields(
                envelope,
                "response envelope",
                "protocol",
                "type",
                "id",
                "ok",
                "result",
                "error"
            );
            for (String required : List.of(
                    "protocol",
                    "type",
                    "id",
                    "ok"
                )) {
                if (!envelope.containsKey(required)) {
                    throw new ProtocolError(
                        "response envelope omitted " + required
                    );
                }
            }
            if (!Wire.PROTOCOL.equals(Wire.string(
                    envelope.get("protocol"),
                    "response protocol"
                ))) {
                throw new ProtocolError(
                    "response protocol is unrecognized"
                );
            }
            if (!"response".equals(Wire.string(
                    envelope.get("type"),
                    "response type"
                ))) {
                throw new ProtocolError("response type is invalid");
            }
            String id = Wire.string(envelope.get("id"), "response id");
            boolean ok = Wire.bool(envelope.get("ok"), "response ok");
            RuntimeException responseError = null;
            Object result = null;
            if (!ok) {
                if (!envelope.containsKey("error") ||
                        envelope.containsKey("result")) {
                    throw new ProtocolError(
                        "failed response requires only error"
                    );
                }
                responseError = decodeResourceError(envelope.get("error"));
            } else {
                if (!envelope.containsKey("result") ||
                        envelope.containsKey("error")) {
                    throw new ProtocolError(
                        "successful response requires only result"
                    );
                }
                result = envelope.get("result");
            }

            CompletableFuture<Object> future = pending.get(id);
            if (future == null || !pending.remove(id, future)) {
                return;
            }
            if (responseError != null) {
                future.completeExceptionally(responseError);
            } else {
                future.complete(result);
            }
        } catch (IllegalArgumentException invalidResponse) {
            throw new ProtocolError(
                "response is malformed",
                invalidResponse
            );
        }
    }

    private void deliverStream(Map<String, Object> envelope) {
        boolean streamEnd = "stream_end".equals(envelope.get("type"));
        if (streamEnd) {
            decodeStreamEnd(envelope);
        } else {
            validateStreamItemEnvelope(envelope);
        }
        Ids.StreamId id = new Ids.StreamId(
            Wire.string(envelope.get(Wire.STREAM_ID), "stream id")
        );
        StreamRoute route = streams.get(id);
        if (route == null) {
            return;
        }
        if (!streamEnd) {
            route.validatePayload(envelope);
            if (route.endDelivered()) {
                throw new ProtocolError(
                    "stream item followed stream_end"
                );
            }
        }
        if (streamEnd && !route.cleanupInProgress()) {
            streams.remove(id, route);
        }
        int size = Wire.json(envelope).getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
        if (route.deliver(new StreamMessage(
                JsonValue.immutableObject(envelope, "stream envelope"),
                null,
                size
            ))) {
            return;
        }
        streams.remove(id, route);
        route.overflow();
        if (route.beginStreamCleanup()) {
            CompletableFuture.runAsync(() -> {
                try {
                    Map<String, Object> result = request(
                        Operations.STREAM_CANCEL,
                        route.cancelParams,
                        null
                    );
                    requireExactFields(result, "stream cancel result");
                } catch (RuntimeException error) {
                    fail(error);
                }
            });
        }
    }

    static void validateStreamItemEnvelope(Map<String, Object> envelope) {
        try {
            requireExactFields(
                envelope,
                "stream item envelope",
                "protocol",
                "type",
                Wire.STREAM_ID,
                "sequence",
                Wire.CURSOR,
                "item"
            );
            for (String required : List.of(
                    "protocol",
                    "type",
                    Wire.STREAM_ID,
                    "sequence",
                    "item"
                )) {
                if (!envelope.containsKey(required)) {
                    throw new ProtocolError(
                        "stream item envelope omitted " + required
                    );
                }
            }
            if (!Wire.PROTOCOL.equals(Wire.string(
                    envelope.get("protocol"),
                    "stream item protocol"
                ))) {
                throw new ProtocolError(
                    "stream item protocol is unrecognized"
                );
            }
            if (!"stream_item".equals(Wire.string(
                    envelope.get("type"),
                    "stream item type"
                ))) {
                throw new ProtocolError("stream item type is invalid");
            }
            new Ids.StreamId(Wire.string(
                envelope.get(Wire.STREAM_ID),
                "stream item stream_id"
            ));
            Wire.decimal(envelope.get("sequence"), "stream item sequence");
            if (envelope.containsKey(Wire.CURSOR)) {
                if (envelope.get(Wire.CURSOR) == null) {
                    throw new ProtocolError(
                        "stream item cursor must not be null"
                    );
                }
                decodeCursor(envelope.get(Wire.CURSOR));
            }
            Wire.object(envelope.get("item"), "stream item payload");
        } catch (IllegalArgumentException invalidItem) {
            throw new ProtocolError(
                "stream item envelope is malformed",
                invalidItem
            );
        }
    }

    private void fail(RuntimeException error) {
        fail(error, true);
    }

    private synchronized void fail(
        RuntimeException error,
        boolean attemptCleanup
    ) {
        if (connectionError == null) {
            connectionError = error;
        }
        RuntimeException terminalError = connectionError;
        if (closed.compareAndSet(false, true)) {
            if (attemptCleanup) {
                cancelFailedStreamOpensBeforeClose();
            }
            try {
                transport.close();
            } catch (IOException closeError) {
                terminalError.addSuppressed(closeError);
            }
        }
        cleanupExecutor.shutdownNow();
        deadlineExecutor.shutdownNow();
        for (CompletableFuture<Object> future : pending.values()) {
            future.completeExceptionally(terminalError);
        }
        pending.clear();
        for (StreamRoute route : streams.values()) {
            route.finish(terminalError);
        }
        streams.clear();
    }

    private void cancelFailedStreamOpensBeforeClose() {
        Thread cleanup = new Thread(() -> {
            if (!tryWriteLock(FAILED_STREAM_OPEN_CLEANUP_TIMEOUT)) {
                return;
            }
            try {
                if (framingUnsafe) {
                    return;
                }
                List<Map<String, Object>> cancelParams = streams.values().stream()
                    .map(StreamRoute::failedOpenCancelParams)
                    .flatMap(Optional::stream)
                    .toList();
                for (Map<String, Object> params : cancelParams) {
                    try {
                        transport.send(streamCancelEnvelope(params));
                    } catch (IOException | RuntimeException ignored) {
                        framingUnsafe = true;
                        return;
                    }
                }
            } finally {
                writeLock.unlock();
            }
        }, "cmux-failed-stream-open-transport-cleanup");
        cleanup.setDaemon(true);
        cleanup.start();
        try {
            cleanup.join(FAILED_STREAM_OPEN_CLEANUP_TIMEOUT.toMillis());
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }

    private Map<String, Object> streamCancelEnvelope(
        Map<String, Object> cancelParams
    ) {
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("protocol", Wire.PROTOCOL);
        envelope.put("type", "request");
        envelope.put("id", "java-" + nextRequest.incrementAndGet());
        envelope.put("operation", Operations.STREAM_CANCEL.wireName());
        envelope.put("params", Wire.encode(cancelParams));
        return envelope;
    }

    private static ThreadPoolExecutor newCleanupExecutor() {
        return new ThreadPoolExecutor(
            1,
            1,
            0L,
            TimeUnit.MILLISECONDS,
            new ArrayBlockingQueue<>(
                FAILED_STREAM_OPEN_CLEANUP_QUEUE_CAPACITY
            ),
            task -> {
                Thread thread = new Thread(
                    task,
                    "cmux-stream-cleanup"
                );
                thread.setDaemon(true);
                return thread;
            },
            new ThreadPoolExecutor.AbortPolicy()
        );
    }

    private static ScheduledThreadPoolExecutor newDeadlineExecutor() {
        ScheduledThreadPoolExecutor executor = new ScheduledThreadPoolExecutor(
            1,
            task -> {
                Thread thread = new Thread(
                    task,
                    "cmux-request-deadline"
                );
                thread.setDaemon(true);
                return thread;
            }
        );
        executor.setRemoveOnCancelPolicy(true);
        executor.setExecuteExistingDelayedTasksAfterShutdownPolicy(false);
        return executor;
    }

    private void finishFailedOpenCleanupGate(AtomicBoolean finished) {
        if (!finished.compareAndSet(false, true)) {
            return;
        }
        boolean acquired = !writeLock.isHeldByCurrentThread();
        if (acquired) {
            writeLock.lock();
        }
        try {
            if (failedOpenCleanups > 0) {
                failedOpenCleanups--;
            }
            failedOpenCleanupFinished.signalAll();
        } finally {
            if (acquired) {
                writeLock.unlock();
            }
        }
    }

    private void lockForRequest(long deadline, String operation) {
        while (true) {
            long remainingBeforeLock = deadline - System.nanoTime();
            if (remainingBeforeLock <= 0L ||
                    !tryWriteLock(Duration.ofNanos(remainingBeforeLock))) {
                throw new TransportError(
                    operation + " timed out waiting to write"
                );
            }
            boolean keepLock = false;
            CompletableFuture<Void> requestCleanup = null;
            try {
                while (failedOpenCleanups > 0 && !closed.get()) {
                    long remaining = deadline - System.nanoTime();
                    if (remaining <= 0L) {
                        throw new TransportError(
                            operation +
                                " timed out waiting for failed stream-open cleanup"
                        );
                    }
                    try {
                        failedOpenCleanupFinished.awaitNanos(remaining);
                    } catch (InterruptedException error) {
                        Thread.currentThread().interrupt();
                        throw new TransportError(
                            "interrupted while waiting for failed stream-open cleanup",
                            error
                        );
                    }
                }
                ensureOpen();
                requestCleanup = activeRequestCleanup();
                if (requestCleanup == null) {
                    keepLock = true;
                    return;
                }
            } finally {
                if (!keepLock) {
                    writeLock.unlock();
                }
            }

            long remaining = deadline - System.nanoTime();
            if (remaining <= 0L) {
                throw new TransportError(
                    operation +
                        " timed out waiting for request cancellation cleanup"
                );
            }
            try {
                requestCleanup.get(remaining, TimeUnit.NANOSECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new TransportError(
                    "interrupted while waiting for request cancellation cleanup",
                    error
                );
            } catch (TimeoutException error) {
                throw new TransportError(
                    operation +
                        " timed out waiting for request cancellation cleanup",
                    error
                );
            } catch (ExecutionException error) {
                throw new TransportError(
                    "request cancellation cleanup failed",
                    error.getCause() == null ? error : error.getCause()
                );
            }
        }
    }

    private void sendWithDeadline(
        Map<String, Object> envelope,
        String operation,
        long deadline
    ) throws IOException {
        long remaining = deadline - System.nanoTime();
        if (remaining <= 0L) {
            throw new TransportError(
                operation + " timed out before dispatch"
            );
        }
        AtomicBoolean dispatchPending = new AtomicBoolean(true);
        ScheduledFuture<?> guard;
        try {
            guard = deadlineExecutor.schedule(
                () -> {
                    if (dispatchPending.compareAndSet(true, false)) {
                        fail(
                            new TransportError(
                                operation + " timed out during dispatch"
                            ),
                            false
                        );
                    }
                },
                remaining,
                TimeUnit.NANOSECONDS
            );
        } catch (RejectedExecutionException rejected) {
            throw closed.get()
                ? closedError()
                : new TransportError(
                    "cannot schedule " + operation + " dispatch deadline",
                    rejected
                );
        }

        boolean completedBeforeDeadline;
        try {
            transport.send(envelope);
        } catch (IOException | RuntimeException error) {
            // Publish framing uncertainty before releasing the writer. A
            // concurrent connection failure must observe this before
            // considering any pre-close cancellation.
            framingUnsafe = true;
            throw error;
        } finally {
            completedBeforeDeadline =
                dispatchPending.compareAndSet(true, false);
            if (completedBeforeDeadline) {
                guard.cancel(false);
            }
        }
        if (!completedBeforeDeadline) {
            throw closedError();
        }
    }

    private static TransportError failedOpenCleanupTimeout() {
        return new TransportError(
            "stream-open cleanup timed out after " +
                FAILED_STREAM_OPEN_CLEANUP_TIMEOUT
        );
    }

    private boolean tryWriteLock(Duration timeout) {
        try {
            return writeLock.tryLock(
                Math.max(1L, timeout.toNanos()),
                TimeUnit.NANOSECONDS
            );
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new TransportError(
                "interrupted while waiting to write",
                error
            );
        }
    }

    private void ensureOpen() {
        if (closed.get()) {
            throw closedError();
        }
    }

    boolean isClosed() {
        return closed.get();
    }

    private RuntimeException closedError() {
        return connectionError == null
            ? new TransportError("client is closed")
            : connectionError;
    }

    static Cursor decodeCursor(Object value) {
        if (value == null) {
            return null;
        }
        Map<String, Object> cursor = Wire.object(value, "cursor");
        requireExactFields(
            cursor,
            "cursor",
            Wire.GENERATION,
            Wire.REVISION
        );
        String generation = Wire.string(
            cursor.get(Wire.GENERATION),
            "cursor generation"
        );
        if (generation.isEmpty() || generation.length() > 128) {
            throw new ProtocolError(
                "cursor generation must contain 1 to 128 characters"
            );
        }
        return new Cursor(
            generation,
            Wire.decimal(cursor.get(Wire.REVISION), "cursor revision")
        );
    }

    static StreamEndError decodeStreamEnd(Map<String, Object> envelope) {
        try {
            return decodeStreamEndFields(envelope);
        } catch (IllegalArgumentException invalidEnd) {
            throw new ProtocolError(
                "stream end envelope is malformed",
                invalidEnd
            );
        }
    }

    private static StreamEndError decodeStreamEndFields(
        Map<String, Object> envelope
    ) {
        requireExactFields(
            envelope,
            "stream end envelope",
            "protocol",
            "type",
            Wire.STREAM_ID,
            "reason",
            Wire.CURSOR,
            "recovery",
            "error"
        );
        for (String required : List.of(
                "protocol",
                "type",
                Wire.STREAM_ID,
                "reason"
            )) {
            if (!envelope.containsKey(required)) {
                throw new ProtocolError(
                    "stream end envelope omitted " + required
                );
            }
        }
        if (!Wire.PROTOCOL.equals(Wire.string(
                envelope.get("protocol"),
                "stream end protocol"
            ))) {
            throw new ProtocolError("stream end protocol is unrecognized");
        }
        if (!"stream_end".equals(Wire.string(
                envelope.get("type"),
                "stream end type"
            ))) {
            throw new ProtocolError("stream end type is invalid");
        }
        new Ids.StreamId(Wire.string(
            envelope.get(Wire.STREAM_ID),
            "stream end stream_id"
        ));
        String reason = Wire.string(
            envelope.get("reason"),
            "stream end reason"
        );
        if (!List.of(
                "completed",
                "canceled",
                "closed",
                "gap",
                "error"
            ).contains(reason)) {
            throw new ProtocolError("stream end reason is unrecognized");
        }
        Optional<Cursor> cursor = Optional.empty();
        if (envelope.containsKey(Wire.CURSOR)) {
            if (envelope.get(Wire.CURSOR) == null) {
                throw new ProtocolError("stream end cursor must not be null");
            }
            cursor = Optional.of(decodeCursor(envelope.get(Wire.CURSOR)));
        }
        Optional<String> recovery = optionalString(envelope, "recovery");
        Optional<ResourceError> error = Optional.empty();
        if (envelope.containsKey("error")) {
            if (envelope.get("error") == null) {
                throw new ProtocolError("stream end error must not be null");
            }
            error = Optional.of(decodeResourceError(envelope.get("error")));
        }
        if (reason.equals("error") != error.isPresent()) {
            throw new ProtocolError(
                "stream end error is present exactly when reason is error"
            );
        }
        return new StreamEndError(
            reason,
            cursor,
            error,
            recovery
        );
    }

    static ResourceError decodeResourceError(Object value) {
        Map<String, Object> error = Wire.object(value, "resource error");
        requireExactFields(
            error,
            "resource error",
            "code",
            "message",
            Wire.DETAILS,
            "retryable"
        );
        for (String required : List.of(
                "code",
                "message",
                Wire.DETAILS,
                "retryable"
            )) {
            if (!error.containsKey(required)) {
                throw new ProtocolError(
                    "resource error omitted required field " + required
                );
            }
        }
        String code = Wire.string(error.get("code"), "error code");
        if (code.isEmpty()) {
            throw new ProtocolError("error code must not be empty");
        }
        return new ResourceError(
            code,
            Wire.string(error.get("message"), "error message"),
            Wire.object(error.get(Wire.DETAILS), "error details"),
            Wire.bool(error.get("retryable"), "error retryable")
        );
    }

    static ConfirmationRequiredDetails decodeConfirmationRequiredDetails(
        Object value
    ) {
        Map<String, Object> details = Wire.object(
            value,
            "confirmation required details"
        );
        requireExactFields(
            details,
            "confirmation required details",
            "confirmation_token",
            Wire.REVISION,
            "closes_panes"
        );
        for (String required : List.of(
                "confirmation_token",
                Wire.REVISION,
                "closes_panes"
            )) {
            if (!details.containsKey(required)) {
                throw new ProtocolError(
                    "confirmation required details omitted " + required
                );
            }
        }
        List<Ids.PaneId> panes = Wire.array(
            details.get("closes_panes"),
            "confirmation closes_panes"
        ).stream()
            .map(item -> new Ids.PaneId(
                Wire.string(item, "confirmation pane id")
            ))
            .toList();
        return new ConfirmationRequiredDetails(
            Wire.string(
                details.get("confirmation_token"),
                "confirmation token"
            ),
            Wire.decimal(details.get(Wire.REVISION), "confirmation revision"),
            panes
        );
    }

    static Map<String, Object> copy(Map<String, Object> value) {
        return new LinkedHashMap<>(value == null ? Map.of() : value);
    }

    static Map<String, Object> selectors(Object... pairs) {
        Map<String, Object> result = Wire.map();
        for (int index = 0; index < pairs.length; index += 2) {
            Object selector = pairs[index + 1];
            if (selector != null) {
                result.put((String) pairs[index], selector);
            }
        }
        return result;
    }

    static void command(Map<String, Object> params, Command command) {
        params.putAll(command.toWire());
    }

    static List<Object> listPayload(Object result, String field) {
        return Wire.array(result, field);
    }

    static Map<String, Object> resourcePayload(Map<String, Object> result, String field) {
        if (result.containsKey(Wire.GENERATION) ||
                result.containsKey(Wire.REVISION) ||
                result.containsKey("replayed")) {
            mutationParts(result);
            return Wire.object(result.get(Wire.VALUE), field);
        }
        return result;
    }

    static MutationParts mutationParts(Map<String, Object> result) {
        for (String key : result.keySet()) {
            if (!List.of(
                    Wire.VALUE,
                    Wire.GENERATION,
                    Wire.REVISION,
                    "replayed"
                ).contains(key)) {
                throw new ProtocolError(
                    "mutation result has unknown field " + key
                );
            }
        }
        if (!result.containsKey(Wire.VALUE) ||
                !result.containsKey(Wire.GENERATION) ||
                !result.containsKey(Wire.REVISION) ||
                !result.containsKey("replayed")) {
            throw new ProtocolError(
                "mutation result requires value, generation, revision, and replayed"
            );
        }
        String generation = Wire.string(
            result.get(Wire.GENERATION),
            "mutation generation"
        );
        if (generation.isEmpty() || generation.length() > 128) {
            throw new ProtocolError(
                "mutation generation must contain 1 to 128 characters"
            );
        }
        Decimal revision = Wire.decimal(
            result.get(Wire.REVISION),
            "mutation revision"
        );
        boolean replayed = Wire.bool(
            result.get("replayed"),
            "mutation replayed"
        );
        return new MutationParts(generation, revision, replayed);
    }

    record MutationParts(
        String generation,
        Decimal revision,
        boolean replayed
    ) {
        <T> MutationResult<T> withValue(T value) {
            return new MutationResult<>(value, generation, revision, replayed);
        }
    }

    record MutationResponse(Map<String, Object> result, MutationParts parts) {}

    MutationResponse mutation(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Map<String, Object> result = request(operation, params, options);
        return new MutationResponse(result, mutationParts(result));
    }

    static CreatedPath decodeCreatedPath(Map<String, Object> result) {
        return decodeCreatedPathValue(result.get(Wire.VALUE));
    }

    private static CreatedPath decodeCreatedPathValue(Object value) {
        Map<String, Object> path = Wire.object(value, "created path");
        String kind = Wire.string(path.get(Wire.KIND), "created path kind");
        return switch (kind) {
            case "workspace" -> {
                requireExactFields(
                    path,
                    "created workspace path",
                    Wire.KIND,
                    "workspace_id"
                );
                yield new CreatedWorkspaceOnly(requiredExactId(
                    path,
                    "workspace_id",
                    Ids.WorkspaceId::new
                ));
            }
            case "terminal" -> {
                requireExactFields(
                    path,
                    "created terminal path",
                    Wire.KIND,
                    "workspace_id",
                    "screen_id",
                    "pane_id",
                    "tab_id",
                    "terminal_id"
                );
                yield new CreatedTerminalPath(
                    requiredExactId(path, "workspace_id", Ids.WorkspaceId::new),
                    requiredExactId(path, "screen_id", Ids.ScreenId::new),
                    requiredExactId(path, "pane_id", Ids.PaneId::new),
                    requiredExactId(path, "tab_id", Ids.TabId::new),
                    requiredExactId(path, "terminal_id", Ids.TerminalId::new)
                );
            }
            case "browser" -> {
                requireExactFields(
                    path,
                    "created browser path",
                    Wire.KIND,
                    "workspace_id",
                    "screen_id",
                    "pane_id",
                    "tab_id",
                    "browser_id"
                );
                yield new CreatedBrowserPath(
                    requiredExactId(path, "workspace_id", Ids.WorkspaceId::new),
                    requiredExactId(path, "screen_id", Ids.ScreenId::new),
                    requiredExactId(path, "pane_id", Ids.PaneId::new),
                    requiredExactId(path, "tab_id", Ids.TabId::new),
                    requiredExactId(path, "browser_id", Ids.BrowserId::new)
                );
            }
            default -> throw new ProtocolError(
                "created path kind is unrecognized"
            );
        };
    }

    static CreatedTerminalPath decodeCreatedTerminalPath(
        Map<String, Object> result
    ) {
        CreatedPath path = decodeCreatedPath(result);
        if (path instanceof CreatedTerminalPath terminal) {
            return terminal;
        }
        throw new ProtocolError("creation result must have terminal kind");
    }

    static CreatedBrowserPath decodeCreatedBrowserPath(
        Map<String, Object> result
    ) {
        CreatedPath path = decodeCreatedPath(result);
        if (path instanceof CreatedBrowserPath browser) {
            return browser;
        }
        throw new ProtocolError("creation result must have browser kind");
    }

    static EmptyResult decodeEmptyMutation(Map<String, Object> result) {
        Map<String, Object> value = Wire.object(
            result.get(Wire.VALUE),
            "empty mutation value"
        );
        requireExactFields(value, "empty mutation value");
        return new EmptyResult();
    }

    static Snapshots.MachineSnapshot decodeMachine(Object value) {
        Map<String, Object> fields = Wire.object(value, "machine snapshot");
        return new Snapshots.MachineSnapshot(
            new Ids.MachineId(Wire.string(fields.get("id"), "machine id")),
            Wire.string(fields.get(Wire.NAME), "machine name"),
            Wire.string(fields.get("origin"), "machine origin"),
            Wire.string(fields.get("status"), "machine status"),
            Wire.bool(fields.get("connectable"), "machine connectable"),
            Wire.bool(fields.get("deleted"), "machine deleted"),
            Wire.bool(fields.get("recoverable"), "machine recoverable"),
            snapshotExtra(
                fields,
                "id",
                Wire.NAME,
                "origin",
                "status",
                "connectable",
                "deleted",
                "recoverable"
            )
        );
    }

    static Snapshots.SessionSnapshot decodeSession(Object value) {
        Map<String, Object> fields = Wire.object(value, "session snapshot");
        String generation = Wire.string(
            fields.get(Wire.GENERATION),
            "session generation"
        );
        if (generation.isEmpty() || generation.length() > 128) {
            throw new ProtocolError(
                "session generation must contain 1 to 128 characters"
            );
        }
        return new Snapshots.SessionSnapshot(
            new Ids.SessionId(Wire.string(fields.get("id"), "session id")),
            requiredExactId(fields, "machine_id", Ids.MachineId::new),
            optionalString(fields, Wire.NAME),
            generation,
            Wire.decimal(fields.get(Wire.REVISION), "session revision"),
            Wire.bool(fields.get("connected"), "session connected"),
            snapshotExtra(
                fields,
                "id",
                "machine_id",
                Wire.NAME,
                Wire.GENERATION,
                Wire.REVISION,
                "connected"
            )
        );
    }

    static Snapshots.WorkspaceSnapshot decodeWorkspace(Object value) {
        Map<String, Object> fields = Wire.object(value, "workspace snapshot");
        return new Snapshots.WorkspaceSnapshot(
            new Ids.WorkspaceId(Wire.string(fields.get("id"), "workspace id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            Wire.string(fields.get(Wire.NAME), "workspace name"),
            uint32(fields, "index"),
            Wire.bool(fields.get(Wire.FOCUSED), "workspace focused"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                Wire.NAME,
                "index",
                Wire.FOCUSED
            )
        );
    }

    static Snapshots.ScreenSnapshot decodeScreen(Object value) {
        Map<String, Object> fields = Wire.object(value, "screen snapshot");
        return new Snapshots.ScreenSnapshot(
            new Ids.ScreenId(Wire.string(fields.get("id"), "screen id")),
            requiredExactId(fields, "workspace_id", Ids.WorkspaceId::new),
            requiredNullableString(fields, Wire.NAME),
            uint32(fields, "index"),
            Wire.bool(fields.get(Wire.FOCUSED), "screen focused"),
            decodeLayoutDocument(fields.get(Wire.LAYOUT)),
            snapshotExtra(
                fields,
                "id",
                "workspace_id",
                Wire.NAME,
                "index",
                Wire.FOCUSED,
                Wire.LAYOUT
            )
        );
    }

    static Snapshots.PaneSnapshot decodePane(Object value) {
        Map<String, Object> fields = Wire.object(value, "pane snapshot");
        return new Snapshots.PaneSnapshot(
            new Ids.PaneId(Wire.string(fields.get("id"), "pane id")),
            requiredExactId(fields, "screen_id", Ids.ScreenId::new),
            requiredNullableString(fields, Wire.NAME),
            Wire.bool(fields.get(Wire.FOCUSED), "pane focused"),
            Wire.bool(fields.get("zoomed"), "pane zoomed"),
            snapshotExtra(
                fields,
                "id",
                "screen_id",
                Wire.NAME,
                Wire.FOCUSED,
                "zoomed"
            )
        );
    }

    static Snapshots.TabSnapshot decodeTab(Object value) {
        Map<String, Object> fields = Wire.object(value, "tab snapshot");
        String kind = Wire.string(fields.get("content_kind"), "tab content kind");
        String content = Wire.string(fields.get("content_id"), "tab content id");
        Ids.Id contentId = switch (kind) {
            case "terminal" -> new Ids.TerminalId(content);
            case "browser" -> new Ids.BrowserId(content);
            default -> throw new IllegalArgumentException(
                "tab content kind must be terminal or browser"
            );
        };
        return new Snapshots.TabSnapshot(
            new Ids.TabId(Wire.string(fields.get("id"), "tab id")),
            requiredExactId(fields, "pane_id", Ids.PaneId::new),
            requiredNullableString(fields, Wire.NAME),
            uint32(fields, "index"),
            Wire.bool(fields.get(Wire.FOCUSED), "tab focused"),
            kind,
            contentId,
            snapshotExtra(
                fields,
                "id",
                "pane_id",
                Wire.NAME,
                "content_kind",
                "content_id",
                "index",
                Wire.FOCUSED
            )
        );
    }

    static Snapshots.TerminalSnapshot decodeTerminal(Object value) {
        Map<String, Object> fields = Wire.object(value, "terminal snapshot");
        Snapshots.TerminalLifecycle lifecycle;
        try {
            lifecycle = Snapshots.TerminalLifecycle.valueOf(
                Wire.string(
                    fields.get("lifecycle"),
                    "terminal lifecycle"
                ).toUpperCase(java.util.Locale.ROOT)
            );
        } catch (IllegalArgumentException error) {
            throw new ProtocolError(
                "terminal lifecycle is unrecognized",
                error
            );
        }
        Optional<Snapshots.TerminalExit> exit = Optional.empty();
        if (fields.containsKey("exit")) {
            Map<String, Object> rawExit = Wire.object(
                fields.get("exit"),
                "terminal exit"
            );
            requireExactFields(
                rawExit,
                "terminal exit",
                "outcome",
                "exited_at",
                Wire.REVISION
            );
            exit = Optional.of(new Snapshots.TerminalExit(
                decodeTerminalExitOutcome(rawExit.get("outcome")),
                Wire.decimal(rawExit.get("exited_at"), "terminal exited_at"),
                Wire.decimal(
                    rawExit.get(Wire.REVISION),
                    "terminal exit revision"
                )
            ));
        }
        boolean hasTabId = fields.containsKey("tab_id");
        boolean hasTabIds = fields.containsKey("tab_ids");
        if (!hasTabId && !hasTabIds) {
            throw new ProtocolError(
                "terminal snapshot requires tab_ids or tab_id"
            );
        }
        Optional<Ids.TabId> legacyTabId = hasTabId
            ? requiredNullableExactId(fields, "tab_id", Ids.TabId::new)
            : Optional.empty();
        List<Ids.TabId> tabIds = hasTabIds
            ? decodeIds(
                fields.get("tab_ids"),
                "terminal tab_ids",
                Ids.TabId::new
            )
            : legacyTabId.map(List::of).orElseGet(List::of);
        if (hasTabId && !Objects.equals(
                legacyTabId.orElse(null),
                tabIds.isEmpty() ? null : tabIds.get(0))) {
            throw new ProtocolError(
                "terminal tab_id must be the first tab_ids item"
            );
        }
        return new Snapshots.TerminalSnapshot(
            new Ids.TerminalId(Wire.string(fields.get("id"), "terminal id")),
            tabIds,
            Wire.string(fields.get(Wire.TITLE), "terminal title"),
            optionalString(fields, Wire.CWD),
            positiveUint16(fields, Wire.COLS),
            positiveUint16(fields, Wire.ROWS),
            Wire.bool(fields.get("running"), "terminal running"),
            lifecycle,
            exit,
            snapshotExtra(
                fields,
                "id",
                "tab_id",
                "tab_ids",
                Wire.TITLE,
                Wire.CWD,
                Wire.COLS,
                Wire.ROWS,
                "running",
                "lifecycle",
                "exit"
            )
        );
    }

    static Snapshots.BrowserSnapshot decodeBrowser(Object value) {
        Map<String, Object> fields = Wire.object(value, "browser snapshot");
        Map<String, Object> size = Wire.object(fields.get("size"), "browser size");
        requireExactFields(size, "browser size", Wire.COLS, Wire.ROWS);
        return new Snapshots.BrowserSnapshot(
            new Ids.BrowserId(Wire.string(fields.get("id"), "browser id")),
            requiredExactId(fields, "tab_id", Ids.TabId::new),
            Wire.string(fields.get(Wire.URL), "browser url"),
            Wire.string(fields.get(Wire.TITLE), "browser title"),
            Wire.bool(fields.get("loading"), "browser loading"),
            Wire.string(fields.get("source"), "browser source"),
            Wire.string(fields.get("status"), "browser status"),
            requiredNullableString(fields, "error"),
            Wire.bool(fields.get("frames_stalled"), "browser frames stalled"),
            decodeSize(size),
            snapshotExtra(
                fields,
                "id",
                "tab_id",
                Wire.URL,
                Wire.TITLE,
                "loading",
                "source",
                "status",
                "error",
                "frames_stalled",
                "size"
            )
        );
    }

    static Snapshots.ClientSnapshot decodeConnectedClient(Object value) {
        Map<String, Object> fields = Wire.object(value, "client snapshot");
        List<Ids.TerminalId> attachedTerminalIds = Wire.array(
            fields.get("attached_terminal_ids"),
            "client attached_terminal_ids"
        ).stream().map(item -> new Ids.TerminalId(
            Wire.string(item, "client attached terminal id")
        )).toList();
        List<Snapshots.ClientTerminalSize> sizes = Wire.array(
            fields.get("sizes"),
            "client sizes"
        ).stream().map(Client::decodeClientTerminalSize).toList();
        return new Snapshots.ClientSnapshot(
            new Ids.ConnectedClientId(Wire.string(fields.get("id"), "client id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            requiredNullableString(fields, Wire.NAME),
            requiredNullableString(fields, "client_kind"),
            Wire.string(fields.get("transport"), "client transport"),
            Wire.decimal(
                fields.get("connected_seconds"),
                "client connected_seconds"
            ),
            attachedTerminalIds,
            sizes,
            Wire.bool(fields.get("self"), "client self"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                Wire.NAME,
                "client_kind",
                "transport",
                "connected_seconds",
                "attached_terminal_ids",
                "sizes",
                "self"
            )
        );
    }

    private static Snapshots.ClientTerminalSize decodeClientTerminalSize(
        Object value
    ) {
        Map<String, Object> fields = Wire.object(value, "client terminal size");
        requireExactFields(
            fields,
            "client terminal size",
            "terminal_id",
            Wire.COLS,
            Wire.ROWS,
            "participating"
        );
        return new Snapshots.ClientTerminalSize(
            requiredExactId(fields, "terminal_id", Ids.TerminalId::new),
            requiredNullableInteger(fields, Wire.COLS),
            requiredNullableInteger(fields, Wire.ROWS),
            Wire.bool(fields.get("participating"), "client size participating")
        );
    }

    static Snapshots.NotificationSnapshot decodeNotification(Object value) {
        Map<String, Object> fields = Wire.object(value, "notification snapshot");
        return new Snapshots.NotificationSnapshot(
            new Ids.NotificationId(
                Wire.string(fields.get("id"), "notification id")
            ),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            Wire.string(fields.get(Wire.TITLE), "notification title"),
            Wire.string(fields.get(Wire.BODY), "notification body"),
            Wire.string(fields.get(Wire.LEVEL), "notification level"),
            optionalExactId(fields, "terminal_id", Ids.TerminalId::new),
            Wire.decimal(
                fields.get("created_at_ms"),
                "notification created_at_ms"
            ),
            Wire.bool(fields.get("unread"), "notification unread"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                Wire.TITLE,
                Wire.BODY,
                Wire.LEVEL,
                "terminal_id",
                "created_at_ms",
                "unread"
            )
        );
    }

    static Snapshots.AgentSnapshot decodeAgent(Object value) {
        Map<String, Object> fields = Wire.object(value, "agent snapshot");
        return new Snapshots.AgentSnapshot(
            new Ids.AgentId(Wire.string(fields.get("id"), "agent id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            requiredExactId(fields, "terminal_id", Ids.TerminalId::new),
            Wire.string(fields.get(Wire.STATE), "agent state"),
            Wire.string(fields.get("source"), "agent source"),
            Wire.decimal(fields.get("updated_at_ms"), "agent updated_at_ms"),
            requiredNullableString(fields, "source_session"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                "terminal_id",
                Wire.STATE,
                "source",
                "updated_at_ms",
                "source_session"
            )
        );
    }

    static Snapshots.PairingRequestSnapshot decodePairingRequest(Object value) {
        Map<String, Object> fields = Wire.object(value, "pairing request snapshot");
        return new Snapshots.PairingRequestSnapshot(
            new Ids.PairingRequestId(
                Wire.string(fields.get("id"), "pairing request id")
            ),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            Wire.string(fields.get("peer"), "pairing request peer"),
            new Secret(Wire.string(fields.get("code"), "pairing request code")),
            Wire.decimal(
                fields.get("expires_in_seconds"),
                "pairing request expires_in_seconds"
            ),
            Wire.string(fields.get("status"), "pairing request status"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                "peer",
                "code",
                "expires_in_seconds",
                "status"
            )
        );
    }

    static Snapshots.FrontendProjectionSnapshot decodeFrontendProjection(
        Object value
    ) {
        Map<String, Object> fields = Wire.object(value, "frontend projection snapshot");
        if (!fields.containsKey("projection")) {
            throw new ProtocolError("frontend projection omitted projection");
        }
        Object rawProjection = fields.get("projection");
        return new Snapshots.FrontendProjectionSnapshot(
            new Ids.ProjectionId(Wire.string(fields.get("id"), "projection id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            Wire.string(fields.get("frontend_id"), "projection frontend_id"),
            Wire.string(fields.get("window_id"), "projection window_id"),
            Wire.string(fields.get("generation"), "projection generation"),
            JsonValue.of(rawProjection),
            Wire.decimal(
                fields.get("projection_revision"),
                "projection revision"
            ),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                "frontend_id",
                "window_id",
                "generation",
                "projection",
                "projection_revision"
            )
        );
    }

    static Snapshots.SidebarViewSnapshot decodeSidebarView(Object value) {
        Map<String, Object> fields = Wire.object(value, "sidebar view snapshot");
        return new Snapshots.SidebarViewSnapshot(
            new Ids.SidebarViewId(Wire.string(fields.get("id"), "sidebar view id")),
            requiredExactId(fields, "session_id", Ids.SessionId::new),
            positiveUint16(fields, Wire.COLS),
            positiveUint16(fields, Wire.ROWS),
            Wire.bool(fields.get("running"), "sidebar view running"),
            snapshotExtra(
                fields,
                "id",
                "session_id",
                Wire.COLS,
                Wire.ROWS,
                "running"
            )
        );
    }

    static Layout.Document decodeLayoutDocument(Object value) {
        Map<String, Object> fields = Wire.object(value, "layout document");
        requireExactFields(
            fields,
            "layout document",
            "version",
            "screen_id",
            "active_pane_id",
            "zoomed_pane_id",
            "root",
            "extra"
        );
        if (!fields.containsKey("zoomed_pane_id")) {
            throw new ProtocolError(
                "layout document omitted required nullable zoomed_pane_id"
            );
        }
        return new Layout.Document(
            uint32(fields, "version"),
            requiredExactId(fields, "screen_id", Ids.ScreenId::new),
            requiredExactId(fields, "active_pane_id", Ids.PaneId::new),
            requiredNullableExactId(
                fields,
                "zoomed_pane_id",
                Ids.PaneId::new
            ),
            decodeLayoutNode(fields.get("root")),
            explicitExtra(fields, "layout document")
        );
    }

    private static Layout.Node decodeLayoutNode(Object value) {
        Map<String, Object> fields = Wire.object(value, "layout node");
        String kind = Wire.string(fields.get(Wire.KIND), "layout node kind");
        return switch (kind) {
            case "leaf" -> {
                requireExactFields(
                    fields,
                    "layout leaf",
                    Wire.KIND,
                    "pane_id",
                    "tab_ids",
                    "active_tab_id"
                );
                yield new Layout.Leaf(
                    requiredExactId(fields, "pane_id", Ids.PaneId::new),
                    decodeIds(
                        fields.get("tab_ids"),
                        "layout tab_ids",
                        Ids.TabId::new
                    ),
                    optionalExactId(fields, "active_tab_id", Ids.TabId::new)
                );
            }
            case "split" -> {
                requireExactFields(
                    fields,
                    "layout split",
                    Wire.KIND,
                    "split_id",
                    Wire.DIRECTION,
                    Wire.RATIO,
                    "first",
                    "second"
                );
                yield new Layout.Split(
                    requiredExactId(fields, "split_id", Ids.SplitId::new),
                    Wire.string(
                        fields.get(Wire.DIRECTION),
                        "layout split direction"
                    ),
                    finiteDouble(fields.get(Wire.RATIO), "layout split ratio"),
                    decodeLayoutNode(fields.get("first")),
                    decodeLayoutNode(fields.get("second"))
                );
            }
            case "stack" -> {
                requireExactFields(
                    fields,
                    "layout stack",
                    Wire.KIND,
                    "pane_ids",
                    "expanded_pane_id"
                );
                yield new Layout.Stack(
                    decodeIds(
                        fields.get("pane_ids"),
                        "layout pane_ids",
                        Ids.PaneId::new
                    ),
                    requiredExactId(
                        fields,
                        "expanded_pane_id",
                        Ids.PaneId::new
                    )
                );
            }
            case "viewport" -> {
                requireExactFields(
                    fields,
                    "layout viewport",
                    Wire.KIND,
                    "base_width",
                    "columns"
                );
                List<Layout.Column> columns = Wire.array(
                    fields.get("columns"),
                    "layout columns"
                ).stream().map(Client::decodeLayoutColumn).toList();
                yield new Layout.Viewport(
                    finiteDouble(
                        fields.get("base_width"),
                        "layout base_width"
                    ),
                    columns
                );
            }
            default -> throw new ProtocolError(
                "layout node kind is unrecognized"
            );
        };
    }

    private static Layout.Column decodeLayoutColumn(Object value) {
        Map<String, Object> fields = Wire.object(value, "layout column");
        requireExactFields(
            fields,
            "layout column",
            "column_id",
            Wire.WIDTH,
            "root"
        );
        return new Layout.Column(
            requiredExactId(fields, "column_id", Ids.SplitId::new),
            finiteDouble(fields.get(Wire.WIDTH), "layout column width"),
            decodeLayoutNode(fields.get("root"))
        );
    }

    static ResourceSnapshot decodeResourceSnapshot(Object value) {
        Map<String, Object> fields = Wire.object(value, "resource snapshot");
        requireExactFields(
            fields,
            "resource snapshot",
            Wire.MACHINE,
            Wire.SESSION,
            "workspaces",
            "screens",
            "panes",
            "tabs",
            "terminals",
            "browsers",
            "clients",
            "notifications",
            "agents",
            "frontend_projections",
            "sidebar_views",
            Wire.CURSOR,
            "extra"
        );
        ResourceSnapshot snapshot = new ResourceSnapshot(
            decodeMachine(fields.get(Wire.MACHINE)),
            decodeSession(fields.get(Wire.SESSION)),
            decodeList(fields, "workspaces", Client::decodeWorkspace),
            decodeList(fields, "screens", Client::decodeScreen),
            decodeList(fields, "panes", Client::decodePane),
            decodeList(fields, "tabs", Client::decodeTab),
            decodeList(fields, "terminals", Client::decodeTerminal),
            decodeList(fields, "browsers", Client::decodeBrowser),
            decodeList(fields, "clients", Client::decodeConnectedClient),
            decodeList(fields, "notifications", Client::decodeNotification),
            decodeList(fields, "agents", Client::decodeAgent),
            decodeList(
                fields,
                "frontend_projections",
                Client::decodeFrontendProjection
            ),
            decodeList(fields, "sidebar_views", Client::decodeSidebarView),
            decodeCursor(fields.get(Wire.CURSOR)),
            explicitExtra(fields, "resource snapshot")
        );
        if (!snapshot.machine().id().equals(snapshot.session().machineId())) {
            throw new ProtocolError(
                "resource snapshot session does not belong to its machine"
            );
        }
        return snapshot;
    }

    static ResourceChange decodeResourceChange(Object value) {
        Map<String, Object> fields = Wire.object(value, "resource change");
        String kind = Wire.string(fields.get(Wire.KIND), "resource change kind");
        if (!kind.equals("upsert") && !kind.equals("delete")) {
            return new ResourceChange.Unknown(kind, fields);
        }
        boolean upsert = kind.equals("upsert");
        requireExactFields(
            fields,
            "resource " + kind,
            upsert
                ? new String[]{
                    Wire.KIND, "sequence", "resource", "id", Wire.VALUE
                }
                : new String[]{Wire.KIND, "sequence", "resource", "id"}
        );
        ResourceChange.ResourceKind resource;
        try {
            resource = ResourceChange.ResourceKind.valueOf(
                Wire.string(fields.get("resource"), "resource kind")
                    .toUpperCase(java.util.Locale.ROOT)
            );
        } catch (IllegalArgumentException error) {
            throw new ProtocolError("resource kind is unrecognized", error);
        }
        Ids.Id id = decodeResourceId(resource, fields.get("id"));
        long sequence = uint32(fields, "sequence");
        if (!upsert) {
            return new ResourceChange.Delete(sequence, resource, id);
        }
        return new ResourceChange.Upsert(
            sequence,
            resource,
            id,
            decodeResourceEntity(resource, fields.get(Wire.VALUE))
        );
    }

    private static Ids.Id decodeResourceId(
        ResourceChange.ResourceKind kind,
        Object value
    ) {
        String text = Wire.string(value, "resource change id");
        return switch (kind) {
            case MACHINE -> new Ids.MachineId(text);
            case SESSION -> new Ids.SessionId(text);
            case WORKSPACE -> new Ids.WorkspaceId(text);
            case SCREEN -> new Ids.ScreenId(text);
            case PANE -> new Ids.PaneId(text);
            case TAB -> new Ids.TabId(text);
            case TERMINAL -> new Ids.TerminalId(text);
            case BROWSER -> new Ids.BrowserId(text);
            case CLIENT -> new Ids.ConnectedClientId(text);
            case NOTIFICATION -> new Ids.NotificationId(text);
            case AGENT -> new Ids.AgentId(text);
            case PAIRING_REQUEST -> new Ids.PairingRequestId(text);
            case FRONTEND_PROJECTION -> new Ids.ProjectionId(text);
            case SIDEBAR_VIEW -> new Ids.SidebarViewId(text);
        };
    }

    private static ResourceEntitySnapshot decodeResourceEntity(
        ResourceChange.ResourceKind kind,
        Object value
    ) {
        return switch (kind) {
            case MACHINE -> decodeMachine(value);
            case SESSION -> decodeSession(value);
            case WORKSPACE -> decodeWorkspace(value);
            case SCREEN -> decodeScreen(value);
            case PANE -> decodePane(value);
            case TAB -> decodeTab(value);
            case TERMINAL -> decodeTerminal(value);
            case BROWSER -> decodeBrowser(value);
            case CLIENT -> decodeConnectedClient(value);
            case NOTIFICATION -> decodeNotification(value);
            case AGENT -> decodeAgent(value);
            case PAIRING_REQUEST -> decodePairingRequest(value);
            case FRONTEND_PROJECTION -> decodeFrontendProjection(value);
            case SIDEBAR_VIEW -> decodeSidebarView(value);
        };
    }

    static Render.Snapshot decodeRenderSnapshot(Object value) {
        Map<String, Object> fields = Wire.object(value, "render snapshot");
        requireExactFields(
            fields,
            "render snapshot",
            "size",
            Wire.CURSOR,
            "default_fg",
            "default_bg",
            "scrollback_rows",
            Wire.ROWS
        );
        return new Render.Snapshot(
            decodeSize(fields.get("size")),
            decodeRenderCursor(fields.get(Wire.CURSOR)),
            Wire.string(fields.get("default_fg"), "render default_fg"),
            Wire.string(fields.get("default_bg"), "render default_bg"),
            uint32(fields, "scrollback_rows"),
            decodeList(fields, Wire.ROWS, Client::decodeRenderRow)
        );
    }

    static Render.Patch decodeRenderPatch(Object value) {
        Map<String, Object> fields = Wire.object(value, "render patch");
        requireExactFields(
            fields,
            "render patch",
            Wire.CURSOR,
            "full_reset",
            "size",
            "default_fg",
            "default_bg",
            "scrollback_rows",
            Wire.ROWS
        );
        return new Render.Patch(
            decodeRenderCursor(fields.get(Wire.CURSOR)),
            Wire.bool(fields.get("full_reset"), "render full_reset"),
            fields.containsKey("size")
                ? Optional.of(decodeSize(fields.get("size")))
                : Optional.empty(),
            optionalString(fields, "default_fg"),
            optionalString(fields, "default_bg"),
            fields.containsKey("scrollback_rows")
                ? Optional.of(uint32(fields, "scrollback_rows"))
                : Optional.empty(),
            decodeList(fields, Wire.ROWS, Client::decodeRenderRow)
        );
    }

    static Render.Scroll decodeRenderScroll(Object value) {
        Map<String, Object> fields = Wire.object(value, "render scroll");
        requireExactFields(fields, "render scroll", "offset", "at_bottom");
        return new Render.Scroll(
            Wire.decimal(fields.get("offset"), "render scroll offset"),
            Wire.bool(fields.get("at_bottom"), "render scroll at_bottom")
        );
    }

    private static Render.Cursor decodeRenderCursor(Object value) {
        Map<String, Object> fields = Wire.object(value, "render cursor");
        requireExactFields(
            fields,
            "render cursor",
            "x",
            "y",
            "style",
            "blink",
            "visible",
            "color"
        );
        if (!fields.containsKey("color")) {
            throw new ProtocolError(
                "render cursor omitted required nullable color"
            );
        }
        return new Render.Cursor(
            uint16(fields, "x"),
            uint16(fields, "y"),
            Wire.string(fields.get("style"), "render cursor style"),
            Wire.bool(fields.get("blink"), "render cursor blink"),
            Wire.bool(fields.get("visible"), "render cursor visible"),
            requiredNullableString(fields, "color")
        );
    }

    private static Render.Row decodeRenderRow(Object value) {
        Map<String, Object> fields = Wire.object(value, "render row");
        requireExactFields(fields, "render row", "row", "runs");
        return new Render.Row(
            uint16(fields, "row"),
            decodeList(fields, "runs", Client::decodeRenderRun)
        );
    }

    private static Render.Run decodeRenderRun(Object value) {
        Map<String, Object> fields = Wire.object(value, "render run");
        requireExactFields(
            fields,
            "render run",
            Wire.TEXT,
            "fg",
            "bg",
            "attrs",
            "underline",
            "width_hint"
        );
        for (String required : List.of("fg", "bg")) {
            if (!fields.containsKey(required)) {
                throw new ProtocolError(
                    "render run omitted required nullable " + required
                );
            }
        }
        return new Render.Run(
            Wire.string(fields.get(Wire.TEXT), "render text"),
            requiredNullableString(fields, "fg"),
            requiredNullableString(fields, "bg"),
            uint32(fields, "attrs"),
            optionalString(fields, "underline"),
            optionalInteger(fields, "width_hint")
        );
    }

    static Results.PingResult decodePingResult(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "ping result",
            "alive",
            Wire.CURSOR
        );
        return new Results.PingResult(
            Wire.bool(fields.get("alive"), "ping alive"),
            decodeCursor(fields.get(Wire.CURSOR))
        );
    }

    static Results.CreationResolution decodeCreationResolution(Object value) {
        Map<String, Object> fields = Wire.object(
            value,
            "creation resolution"
        );
        requireExactFields(
            fields,
            "creation resolution",
            "correlation_key",
            Wire.STATE,
            "recovery",
            "operation",
            Wire.IDEMPOTENCY_KEY,
            "created_path",
            Wire.GENERATION,
            Wire.REVISION
        );
        Results.CreationState state;
        Results.CreationRecovery recovery;
        try {
            state = Results.CreationState.valueOf(
                Wire.string(fields.get(Wire.STATE), "creation state")
                    .toUpperCase(java.util.Locale.ROOT)
            );
            recovery = Results.CreationRecovery.valueOf(
                Wire.string(fields.get("recovery"), "creation recovery")
                    .toUpperCase(java.util.Locale.ROOT)
            );
        } catch (IllegalArgumentException error) {
            throw new ProtocolError(
                "creation resolution has an unrecognized state or recovery",
                error
            );
        }
        Optional<CreatedPath> createdPath = fields.containsKey("created_path")
            ? Optional.of(decodeCreatedPathValue(fields.get("created_path")))
            : Optional.empty();
        Optional<Decimal> revision = fields.containsKey(Wire.REVISION)
            ? Optional.of(Wire.decimal(
                fields.get(Wire.REVISION),
                "creation revision"
            ))
            : Optional.empty();
        try {
            return new Results.CreationResolution(
                Wire.string(
                    fields.get("correlation_key"),
                    "creation correlation_key"
                ),
                state,
                recovery,
                optionalString(fields, "operation"),
                optionalString(fields, Wire.IDEMPOTENCY_KEY),
                createdPath,
                optionalString(fields, Wire.GENERATION),
                revision
            );
        } catch (IllegalArgumentException error) {
            throw new ProtocolError("invalid creation resolution", error);
        }
    }

    static Results.ShutdownResult decodeShutdownResult(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "shutdown result",
            "accepted"
        );
        return new Results.ShutdownResult(
            Wire.bool(fields.get("accepted"), "shutdown accepted")
        );
    }

    static Results.ReloadConfigResult decodeReloadConfigResult(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "reload config result",
            "reloaded",
            "warnings"
        );
        return new Results.ReloadConfigResult(
            Wire.bool(fields.get("reloaded"), "reload config reloaded"),
            Wire.array(fields.get("warnings"), "reload config warnings").stream()
                .map(item -> Wire.string(item, "reload config warning"))
                .toList()
        );
    }

    static Results.TerminalDefaultsSnapshot decodeTerminalDefaults(
        Object value
    ) {
        Map<String, Object> fields = Wire.object(
            value,
            "terminal defaults snapshot"
        );
        requireExactFields(
            fields,
            "terminal defaults snapshot",
            "foreground",
            "background",
            Wire.CURSOR,
            "selection_background",
            "selection_foreground",
            "cursor_style",
            "cursor_blink",
            "palette"
        );
        Optional<Map<String, String>> palette = Optional.empty();
        if (fields.containsKey("palette")) {
            Map<String, Object> raw = Wire.object(
                fields.get("palette"),
                "terminal defaults palette"
            );
            Map<String, String> decoded = new LinkedHashMap<>();
            for (Map.Entry<String, Object> entry : raw.entrySet()) {
                decoded.put(
                    entry.getKey(),
                    Wire.string(entry.getValue(), "terminal palette color")
                );
            }
            palette = Optional.of(Map.copyOf(decoded));
        }
        return new Results.TerminalDefaultsSnapshot(
            nullableDefault(fields, "foreground", Wire::string),
            nullableDefault(fields, "background", Wire::string),
            nullableDefault(fields, Wire.CURSOR, Wire::string),
            nullableDefault(fields, "selection_background", Wire::string),
            nullableDefault(fields, "selection_foreground", Wire::string),
            nullableDefault(fields, "cursor_style", Wire::string),
            nullableDefault(fields, "cursor_blink", Wire::bool),
            palette
        );
    }

    static Results.PairingResolutionResult decodePairingResolution(
        Object value
    ) {
        Map<String, Object> fields = exactObject(
            value,
            "pairing resolution result",
            "pairing_request"
        );
        return new Results.PairingResolutionResult(
            decodePairingRequest(fields.get("pairing_request"))
        );
    }

    static Results.PaneNeighborResult decodePaneNeighbor(Object value) {
        Map<String, Object> fields = Wire.object(
            value,
            "pane neighbor result"
        );
        requireExactFields(fields, "pane neighbor result", Wire.PANE);
        return new Results.PaneNeighborResult(
            !fields.containsKey(Wire.PANE) || fields.get(Wire.PANE) == null
                ? Optional.empty()
                : Optional.of(decodePane(fields.get(Wire.PANE)))
        );
    }

    static Results.TerminalScreenResult decodeTerminalScreen(Object value) {
        Map<String, Object> fields = Wire.object(value, "terminal screen result");
        requireExactFields(
            fields,
            "terminal screen result",
            Wire.TEXT,
            Wire.COLS,
            Wire.ROWS,
            "cursor_row",
            "cursor_col",
            "cursor_visible",
            "extra"
        );
        return new Results.TerminalScreenResult(
            Wire.string(fields.get(Wire.TEXT), "terminal screen text"),
            positiveUint16(fields, Wire.COLS),
            positiveUint16(fields, Wire.ROWS),
            uint16(fields, "cursor_row"),
            uint16(fields, "cursor_col"),
            Wire.bool(fields.get("cursor_visible"), "terminal cursor visible"),
            explicitExtra(fields, "terminal screen result")
        );
    }

    static Results.TerminalHistoryResult decodeTerminalHistory(Object value) {
        Map<String, Object> fields = Wire.object(value, "terminal history result");
        requireExactFields(
            fields,
            "terminal history result",
            Wire.START,
            "next",
            Wire.ROWS
        );
        return new Results.TerminalHistoryResult(
            Wire.decimal(fields.get(Wire.START), "history start"),
            nullableDefault(fields, "next", Wire::decimal),
            decodeList(fields, Wire.ROWS, Client::decodeRenderRow)
        );
    }

    static Results.TerminalStateResult decodeTerminalState(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "terminal state result",
            "state_base64",
            Wire.COLS,
            Wire.ROWS
        );
        return new Results.TerminalStateResult(
            decodeBase64(fields.get("state_base64"), "terminal state_base64"),
            positiveUint16(fields, Wire.COLS),
            positiveUint16(fields, Wire.ROWS)
        );
    }

    static Results.TerminalWaitResult decodeTerminalWait(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "terminal wait result",
            "matched",
            Wire.TEXT
        );
        return new Results.TerminalWaitResult(
            Wire.bool(fields.get("matched"), "terminal wait matched"),
            Wire.string(fields.get(Wire.TEXT), "terminal wait text")
        );
    }

    static Results.TerminalWaitExitResult decodeTerminalWaitExit(Object value) {
        Map<String, Object> fields = Wire.object(
            value,
            "terminal wait-exit result"
        );
        String state = Wire.string(
            fields.get(Wire.STATE),
            "terminal wait-exit state"
        );
        if (state.equals("pending")) {
            fields = exactObject(
                value,
                "terminal wait-exit pending",
                Wire.STATE,
                "terminal_id",
                "lifecycle",
                Wire.REVISION
            );
            try {
                return new Results.TerminalWaitExitPending(
                    requiredExactId(
                        fields,
                        "terminal_id",
                        Ids.TerminalId::new
                    ),
                    Wire.string(
                        fields.get("lifecycle"),
                        "terminal lifecycle"
                    ),
                    Wire.decimal(
                        fields.get(Wire.REVISION),
                        "terminal exit revision"
                    )
                );
            } catch (IllegalArgumentException error) {
                throw new ProtocolError(
                    "invalid pending terminal exit result",
                    error
                );
            }
        }
        if (!state.equals("exited")) {
            throw new ProtocolError("terminal wait-exit state is unrecognized");
        }
        fields = exactObject(
            value,
            "terminal wait-exit exited",
            Wire.STATE,
            "terminal_id",
            "lifecycle",
            "outcome",
            "exited_at",
            Wire.REVISION
        );
        if (!Wire.string(
                fields.get("lifecycle"),
                "terminal lifecycle"
            ).equals("exited")) {
            throw new ProtocolError(
                "exited terminal result requires exited lifecycle"
            );
        }
        return new Results.TerminalWaitExitExited(
            requiredExactId(fields, "terminal_id", Ids.TerminalId::new),
            decodeTerminalExitOutcome(fields.get("outcome")),
            Wire.decimal(fields.get("exited_at"), "terminal exited_at"),
            Wire.decimal(fields.get(Wire.REVISION), "terminal exit revision")
        );
    }

    private static Results.TerminalExitOutcome decodeTerminalExitOutcome(
        Object value
    ) {
        Map<String, Object> fields = Wire.object(
            value,
            "terminal exit outcome"
        );
        String kind = Wire.string(
            fields.get(Wire.KIND),
            "terminal exit outcome kind"
        );
        return switch (kind) {
            case "exit" -> {
                fields = exactObject(
                    value,
                    "terminal exit code",
                    Wire.KIND,
                    "code"
                );
                yield new Results.TerminalExitCode(
                    integer(fields, "code")
                );
            }
            case "signal" -> {
                fields = exactObject(
                    value,
                    "terminal exit signal",
                    Wire.KIND,
                    "signal",
                    "core_dumped"
                );
                try {
                    yield new Results.TerminalExitSignal(
                        integer(fields, "signal"),
                        Wire.bool(
                            fields.get("core_dumped"),
                            "terminal core_dumped"
                        )
                    );
                } catch (IllegalArgumentException error) {
                    throw new ProtocolError(
                        "invalid terminal exit signal",
                        error
                    );
                }
            }
            case "unknown" -> {
                fields = exactObject(
                    value,
                    "terminal exit unknown",
                    Wire.KIND,
                    "reason"
                );
                try {
                    yield new Results.TerminalExitUnknown(
                        Wire.string(
                            fields.get("reason"),
                            "terminal exit reason"
                        )
                    );
                } catch (IllegalArgumentException error) {
                    throw new ProtocolError(
                        "invalid unknown terminal exit",
                        error
                    );
                }
            }
            default -> throw new ProtocolError(
                "terminal exit outcome kind is unrecognized"
            );
        };
    }

    static Results.TerminalCopyResult decodeTerminalCopy(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "terminal copy result",
            Wire.MODE,
            Wire.TEXT
        );
        return new Results.TerminalCopyResult(
            Wire.string(fields.get(Wire.MODE), "terminal copy mode"),
            Wire.string(fields.get(Wire.TEXT), "terminal copy text")
        );
    }

    static Results.ProcessInfoResult decodeProcessInfo(Object value) {
        Map<String, Object> fields = Wire.object(value, "process info result");
        requireExactFields(
            fields,
            "process info result",
            "pid",
            "executable",
            Wire.ARGV,
            Wire.CWD,
            "foreground_cwd",
            "children"
        );
        return new Results.ProcessInfoResult(
            uint32(fields, "pid"),
            optionalString(fields, "executable"),
            Wire.array(fields.get(Wire.ARGV), "process argv").stream()
                .map(item -> Wire.string(item, "process argv item"))
                .toList(),
            optionalString(fields, Wire.CWD),
            fields.containsKey("foreground_cwd")
                ? requiredNullableString(fields, "foreground_cwd")
                : Optional.empty(),
            Wire.array(fields.get("children"), "process children").stream()
                .map(item -> uint32(item, "process child"))
                .toList()
        );
    }

    static RendererGrant decodeRendererGrant(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "renderer grant result",
            "endpoint",
            "terminal_id",
            "token",
            "rights",
            "ttl_ms"
        );
        String token = Wire.string(fields.get("token"), "renderer token");
        if (token.isEmpty()) {
            throw new ProtocolError("renderer token must not be empty");
        }
        List<String> rights = Wire.array(
            fields.get("rights"),
            "renderer rights"
        ).stream().map(item -> Wire.string(item, "renderer right")).toList();
        if (rights.isEmpty()) {
            throw new ProtocolError("renderer rights must not be empty");
        }
        long ttl = uint32(fields, "ttl_ms");
        if (ttl < 1 || ttl > 60_000) {
            throw new ProtocolError(
                "renderer ttl_ms must be between 1 and 60000"
            );
        }
        return new RendererGrant(
            Wire.string(fields.get("endpoint"), "renderer endpoint"),
            requiredExactId(fields, "terminal_id", Ids.TerminalId::new),
            new Secret(token),
            rights,
            Math.toIntExact(ttl)
        );
    }

    static Results.CellPixelsResult decodeCellPixels(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "cell pixels result",
            "width_px",
            "height_px",
            "resized_terminals",
            "failures"
        );
        Map<String, Object> rawFailures = Wire.object(
            fields.get("failures"),
            "cell pixel failures"
        );
        Map<String, String> failures = new LinkedHashMap<>();
        for (Map.Entry<String, Object> entry : rawFailures.entrySet()) {
            failures.put(
                entry.getKey(),
                Wire.string(entry.getValue(), "cell pixel failure")
            );
        }
        return new Results.CellPixelsResult(
            positiveUint32(fields, "width_px"),
            positiveUint32(fields, "height_px"),
            decodeIds(
                fields.get("resized_terminals"),
                "resized terminals",
                Ids.TerminalId::new
            ),
            failures
        );
    }

    static Results.ViewerResizeResult decodeViewerResize(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "viewer resize result",
            "accepted",
            "size",
            "outcome"
        );
        return new Results.ViewerResizeResult(
            Wire.bool(fields.get("accepted"), "viewer resize accepted"),
            decodeSize(fields.get("size")),
            decodeViewAttachmentOutcome(fields.get("outcome"))
        );
    }

    static Results.BrowserViewerResizeResult decodeBrowserViewerResize(
        Object value
    ) {
        Map<String, Object> fields = exactObject(
            value,
            "browser viewer resize result",
            "accepted",
            "size",
            "outcome"
        );
        return new Results.BrowserViewerResizeResult(
            Wire.bool(fields.get("accepted"), "browser resize accepted"),
            decodePixelSize(fields.get("size")),
            decodeViewAttachmentOutcome(fields.get("outcome"))
        );
    }

    static Results.ViewerReleaseResult decodeViewerRelease(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "viewer release result",
            "outcome"
        );
        return new Results.ViewerReleaseResult(
            decodeViewAttachmentOutcome(fields.get("outcome"))
        );
    }

    private static Results.ViewAttachmentOutcome decodeViewAttachmentOutcome(
        Object value
    ) {
        return switch (Wire.string(value, "view attachment outcome")) {
            case "applied" -> Results.ViewAttachmentOutcome.APPLIED;
            case "passive" -> Results.ViewAttachmentOutcome.PASSIVE;
            case "superseded" -> Results.ViewAttachmentOutcome.SUPERSEDED;
            default -> throw new ProtocolError("invalid view attachment outcome");
        };
    }

    static EmptyResult decodeEmptyResult(Object value, String context) {
        Map<String, Object> fields = exactObject(value, context);
        return new EmptyResult();
    }

    private static Snapshots.Size decodeSize(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "size",
            Wire.COLS,
            Wire.ROWS
        );
        return new Snapshots.Size(
            positiveUint16(fields, Wire.COLS),
            positiveUint16(fields, Wire.ROWS)
        );
    }

    static Snapshots.PixelSize decodePixelSize(Object value) {
        Map<String, Object> fields = exactObject(
            value,
            "pixel size",
            "width_px",
            "height_px"
        );
        return new Snapshots.PixelSize(
            positiveUint32(fields, "width_px"),
            positiveUint32(fields, "height_px")
        );
    }

    private static Map<String, Object> exactObject(
        Object value,
        String context,
        String... fields
    ) {
        Map<String, Object> decoded = Wire.object(value, context);
        requireExactFields(decoded, context, fields);
        for (String field : fields) {
            if (!decoded.containsKey(field)) {
                throw new ProtocolError(
                    context + " omitted required field " + field
                );
            }
        }
        return decoded;
    }

    private static Map<String, Object> explicitExtra(
        Map<String, Object> fields,
        String context
    ) {
        if (!fields.containsKey("extra")) {
            return Map.of();
        }
        return JsonValue.immutableObject(
            Wire.object(fields.get("extra"), context + " extra"),
            context + " extra"
        );
    }

    private static <T> List<T> decodeList(
        Map<String, Object> fields,
        String key,
        ValueDecoder<T> decoder
    ) {
        return Wire.array(fields.get(key), key).stream()
            .map(decoder::decode)
            .toList();
    }

    private static <T> List<T> decodeIds(
        Object value,
        String context,
        java.util.function.Function<String, T> constructor
    ) {
        return Wire.array(value, context).stream()
            .map(item -> constructor.apply(Wire.string(item, context + " item")))
            .toList();
    }

    @FunctionalInterface
    private interface NullableDecoder<T> {
        T decode(Object value, String context);
    }

    private static <T> Results.NullableDefault<T> nullableDefault(
        Map<String, Object> fields,
        String key,
        NullableDecoder<T> decoder
    ) {
        if (!fields.containsKey(key)) {
            return Results.NullableDefault.absent();
        }
        if (fields.get(key) == null) {
            return Results.NullableDefault.nullValue();
        }
        return Results.NullableDefault.of(
            decoder.decode(fields.get(key), key)
        );
    }

    static byte[] decodeBase64(Object value, String context) {
        String encoded = Wire.string(value, context);
        if (encoded.length() % 4 != 0 ||
                !encoded.matches(
                    "(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?"
                )) {
            throw new ProtocolError(context + " must be canonical base64");
        }
        try {
            return Base64.getDecoder().decode(encoded);
        } catch (IllegalArgumentException error) {
            throw new ProtocolError(context + " is invalid", error);
        }
    }

    private static int uint16(Map<String, Object> fields, String key) {
        long value = integerLong(fields.get(key), key);
        if (value < 0 || value > 0xffffL) {
            throw new ProtocolError(key + " must fit uint16");
        }
        return Math.toIntExact(value);
    }

    private static int positiveUint16(
        Map<String, Object> fields,
        String key
    ) {
        int value = uint16(fields, key);
        if (value == 0) {
            throw new ProtocolError(key + " must be positive");
        }
        return value;
    }

    private static long uint32(Map<String, Object> fields, String key) {
        return uint32(fields.get(key), key);
    }

    private static long uint32(Object value, String context) {
        long decoded = integerLong(value, context);
        if (decoded < 0 || decoded > 0xffff_ffffL) {
            throw new ProtocolError(context + " must fit uint32");
        }
        return decoded;
    }

    private static long positiveUint32(
        Map<String, Object> fields,
        String key
    ) {
        long value = uint32(fields, key);
        if (value == 0) {
            throw new ProtocolError(key + " must be positive");
        }
        return value;
    }

    private static long integerLong(Object value, String context) {
        if (!(value instanceof Number number)) {
            throw new ProtocolError(context + " must be an integer");
        }
        try {
            return new java.math.BigDecimal(number.toString()).longValueExact();
        } catch (ArithmeticException | NumberFormatException error) {
            throw new ProtocolError(
                context + " must fit a signed 64-bit integer",
                error
            );
        }
    }

    private static double finiteDouble(Object value, String context) {
        if (!(value instanceof Number number)) {
            throw new ProtocolError(context + " must be a number");
        }
        double decoded = number.doubleValue();
        if (!Double.isFinite(decoded)) {
            throw new ProtocolError(context + " must be finite");
        }
        return decoded;
    }

    static Optional<String> optionalString(Map<String, Object> fields, String key) {
        if (!fields.containsKey(key)) {
            return Optional.empty();
        }
        Object value = fields.get(key);
        if (value == null) {
            throw new ProtocolError(key + " must not be null");
        }
        return Optional.of(Wire.string(value, key));
    }

    static Optional<String> requiredNullableString(
        Map<String, Object> fields,
        String key
    ) {
        if (!fields.containsKey(key)) {
            throw new ProtocolError(key + " is required, although it may be null");
        }
        Object value = fields.get(key);
        return value == null
            ? Optional.empty()
            : Optional.of(Wire.string(value, key));
    }

    static Optional<Decimal> optionalDecimal(Map<String, Object> fields) {
        return fields.get(Wire.REVISION) == null
            ? Optional.empty()
            : Optional.of(Wire.decimal(fields.get(Wire.REVISION), Wire.REVISION));
    }

    static int integer(Map<String, Object> fields, String key) {
        Object value = fields.get(key);
        if (!(value instanceof Number number)) {
            throw new IllegalArgumentException(key + " must be an integer");
        }
        try {
            return new java.math.BigDecimal(number.toString()).intValueExact();
        } catch (ArithmeticException error) {
            throw new IllegalArgumentException(key + " must fit a signed 32-bit integer", error);
        }
    }

    static Optional<Integer> optionalInteger(
        Map<String, Object> fields,
        String key
    ) {
        if (!fields.containsKey(key)) {
            return Optional.empty();
        }
        if (fields.get(key) == null) {
            throw new ProtocolError(key + " must not be null");
        }
        return Optional.of(integer(fields, key));
    }

    static Optional<Long> optionalUint32(
        Map<String, Object> fields,
        String key
    ) {
        if (!fields.containsKey(key)) {
            return Optional.empty();
        }
        if (fields.get(key) == null) {
            throw new ProtocolError(key + " must not be null");
        }
        return Optional.of(uint32(fields, key));
    }

    static Optional<Integer> requiredNullableInteger(
        Map<String, Object> fields,
        String key
    ) {
        if (!fields.containsKey(key)) {
            throw new ProtocolError(key + " is required, although it may be null");
        }
        return fields.get(key) == null
            ? Optional.empty()
            : Optional.of(integer(fields, key));
    }

    static Map<String, Object> optionalObject(
        Map<String, Object> fields,
        String key
    ) {
        Object value = fields.get(key);
        return value == null ? Map.of() : Wire.object(value, key);
    }

    static List<Object> optionalArray(Map<String, Object> fields, String key) {
        Object value = fields.get(key);
        return value == null ? List.of() : Wire.array(value, key);
    }

    static Map<String, Object> extra(Map<String, Object> fields, String... known) {
        Map<String, Object> result = copy(fields);
        result.keySet().removeAll(List.of(known));
        return JsonValue.immutableObject(result, "extra");
    }

    static Map<String, Object> snapshotExtra(
        Map<String, Object> fields,
        String... known
    ) {
        Map<String, Object> result = copy(fields);
        result.keySet().removeAll(List.of(known));
        boolean hasExplicitExtra = result.containsKey("extra");
        Object explicit = result.remove("extra");
        if (!result.isEmpty()) {
            throw new ProtocolError(
                "snapshot has unknown fields " + result.keySet()
            );
        }
        if (!hasExplicitExtra) {
            return Map.of();
        }
        return JsonValue.immutableObject(
            Wire.object(explicit, "snapshot extra"),
            "snapshot extra"
        );
    }

    static void requireExactFields(
        Map<String, Object> fields,
        String context,
        String... allowed
    ) {
        for (String key : fields.keySet()) {
            if (!List.of(allowed).contains(key)) {
                throw new ProtocolError(
                    context + " has unknown field " + key
                );
            }
        }
    }

    private static <T> Optional<T> optionalId(
        Map<String, Object> fields,
        String key,
        java.util.function.Function<String, T> constructor
    ) {
        Object value = fields.get(key);
        if (value == null) {
            value = fields.get(key + "_id");
        }
        return value == null
            ? Optional.empty()
            : Optional.of(constructor.apply(Wire.string(value, key)));
    }

    private static <T> T requiredId(
        Map<String, Object> fields,
        String key,
        java.util.function.Function<String, T> constructor
    ) {
        return optionalId(fields, key, constructor).orElseThrow(
            () -> new IllegalArgumentException(key + " id is required")
        );
    }

    private static <T> Optional<T> optionalExactId(
        Map<String, Object> fields,
        String key,
        java.util.function.Function<String, T> constructor
    ) {
        if (!fields.containsKey(key)) {
            return Optional.empty();
        }
        Object value = fields.get(key);
        if (value == null) {
            throw new ProtocolError(key + " must not be null");
        }
        return Optional.of(constructor.apply(Wire.string(value, key)));
    }

    private static <T> Optional<T> requiredNullableExactId(
        Map<String, Object> fields,
        String key,
        java.util.function.Function<String, T> constructor
    ) {
        if (!fields.containsKey(key)) {
            throw new ProtocolError(key + " is required, although it may be null");
        }
        Object value = fields.get(key);
        return value == null
            ? Optional.empty()
            : Optional.of(constructor.apply(Wire.string(value, key)));
    }

    private static <T> T requiredExactId(
        Map<String, Object> fields,
        String key,
        java.util.function.Function<String, T> constructor
    ) {
        return optionalExactId(fields, key, constructor).orElseThrow(
            () -> new ProtocolError(key + " is required")
        );
    }

    private static Duration positive(Duration value, String name) {
        Objects.requireNonNull(value, name);
        if (value.isNegative() || value.isZero()) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return value;
    }

    private static RuntimeException transportError(String message, Throwable error) {
        return error instanceof RuntimeException runtime
            ? runtime
            : new TransportError(message, error);
    }

    private static RuntimeException uncertain(
        Operations operation,
        String idempotencyKey,
        RuntimeException failure
    ) {
        return idempotencyKey == null
            ? failure
            : new MutationOutcomeUncertain(
                operation.wireName(),
                idempotencyKey,
                failure
            );
    }

    private static Supplier<String> randomSource(String prefix) {
        SecureRandom random = new SecureRandom();
        return () -> {
            byte[] entropy = new byte[16];
            random.nextBytes(entropy);
            return prefix + LOWERCASE_HEX.formatHex(entropy);
        };
    }

    public static final class Builder {
        private Path socket;
        private String session = "main";
        private Duration timeout = Duration.ofSeconds(10);
        private int maxRequestBytes = MAX_REQUEST_BYTES;
        private int maxResponseBytes = MAX_RESPONSE_BYTES;
        private Transport transport;
        private Supplier<String> idempotencyKeys;
        private Supplier<String> streamIds;

        private Builder() {}

        public Builder socket(Path value) { socket = value; return this; }
        public Builder session(String value) { session = Objects.requireNonNull(value, "value"); return this; }
        public Builder timeout(Duration value) { timeout = value; return this; }
        public Builder maxRequestBytes(int value) { maxRequestBytes = value; return this; }
        public Builder maxResponseBytes(int value) { maxResponseBytes = value; return this; }
        public Builder transport(Transport value) { transport = Objects.requireNonNull(value, "value"); return this; }
        public Builder idempotencyKeySource(Supplier<String> value) { idempotencyKeys = Objects.requireNonNull(value, "value"); return this; }
        public Builder streamIdSource(Supplier<String> value) { streamIds = Objects.requireNonNull(value, "value"); return this; }
        public Client build() { return new Client(this); }
    }
}
