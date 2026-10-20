package com.cmux;

public class TransportError extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public TransportError(String message) {
        super(message);
    }

    public TransportError(String message, Throwable cause) {
        super(message, cause);
    }
}
