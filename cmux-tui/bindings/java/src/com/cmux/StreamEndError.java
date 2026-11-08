package com.cmux;

import java.util.Optional;

@SuppressWarnings("serial")
public final class StreamEndError extends RuntimeException {
    private static final long serialVersionUID = 1L;
    private final String reason;
    private final Optional<Cursor> cursor;
    private final Optional<ResourceError> resourceError;
    private final Optional<String> recovery;

    public StreamEndError(
        String reason,
        Optional<Cursor> cursor,
        Optional<ResourceError> resourceError,
        Optional<String> recovery
    ) {
        super(message(reason, resourceError));
        this.reason = reason;
        this.cursor = cursor == null ? Optional.empty() : cursor;
        this.resourceError = resourceError == null ? Optional.empty() : resourceError;
        this.recovery = recovery == null ? Optional.empty() : recovery;
    }

    public String reason() {
        return reason;
    }

    public Optional<Cursor> cursor() {
        return cursor;
    }

    public Optional<ResourceError> resourceError() {
        return resourceError;
    }

    public Optional<String> recovery() {
        return recovery;
    }

    private static String message(String reason, Optional<ResourceError> error) {
        return "cmux stream ended (" + reason + ")" +
            (error != null && error.isPresent() ? ": " + error.get() : "");
    }
}
