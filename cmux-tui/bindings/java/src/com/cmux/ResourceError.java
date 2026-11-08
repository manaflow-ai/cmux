package com.cmux;

import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Structured server error with forward-compatible details. */
@SuppressWarnings("serial")
public final class ResourceError extends RuntimeException {
    private static final long serialVersionUID = 1L;
    private final String code;
    private final Map<String, Object> details;
    private final boolean retryable;
    private final Optional<ConfirmationRequiredDetails>
        confirmationRequiredDetails;

    public ResourceError(
        String code,
        String message,
        Map<String, Object> details,
        boolean retryable
    ) {
        super(Objects.requireNonNull(message, "message"));
        this.code = Objects.requireNonNull(code, "code");
        this.details = JsonValue.immutableObject(details, "error details");
        this.retryable = retryable;
        this.confirmationRequiredDetails = code.equals("confirmation.required")
            ? Optional.of(Client.decodeConfirmationRequiredDetails(this.details))
            : Optional.empty();
    }

    public String code() {
        return code;
    }

    public Map<String, Object> details() {
        return details;
    }

    public boolean retryable() {
        return retryable;
    }

    public Optional<ConfirmationRequiredDetails> confirmationRequiredDetails() {
        return confirmationRequiredDetails;
    }

    @Override
    public String toString() {
        return code + ": " + getMessage();
    }
}
