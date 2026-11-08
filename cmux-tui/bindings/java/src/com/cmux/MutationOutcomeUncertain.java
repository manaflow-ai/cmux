package com.cmux;

import java.util.Objects;

/**
 * A mutation request lost its transport before a structured response arrived.
 *
 * <p>The operation may have committed. Inspect state before deciding whether
 * to retry with a new idempotency key.</p>
 */
public final class MutationOutcomeUncertain extends TransportError {
    private static final long serialVersionUID = 1L;

    private final String operation;
    private final String idempotencyKey;

    MutationOutcomeUncertain(
        String operation,
        String idempotencyKey,
        Throwable cause
    ) {
        super(
            operation + " lost its response; outcome is uncertain for idempotency key " +
                idempotencyKey,
            cause
        );
        this.operation = Objects.requireNonNull(operation, "operation");
        this.idempotencyKey = Objects.requireNonNull(
            idempotencyKey,
            "idempotencyKey"
        );
    }

    public String operation() {
        return operation;
    }

    public String idempotencyKey() {
        return idempotencyKey;
    }
}
