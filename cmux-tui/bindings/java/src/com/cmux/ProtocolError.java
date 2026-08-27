package com.cmux;

public final class ProtocolError extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public ProtocolError(String message) {
        super(message);
    }

    public ProtocolError(String message, Throwable cause) {
        super(message, cause);
    }
}
