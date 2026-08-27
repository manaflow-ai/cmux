package com.cmux.raw;

/** The server sent more pre-acknowledgement events than the configured stream buffer allows. */
public final class CmuxStreamBufferOverflowException extends CmuxException {
    private static final long serialVersionUID = 1L;

    private final int limit;

    public CmuxStreamBufferOverflowException(int limit) {
        super("pre-acknowledgement stream event buffer exceeds configured limit " + limit);
        this.limit = limit;
    }

    public int limit() {
        return limit;
    }
}
