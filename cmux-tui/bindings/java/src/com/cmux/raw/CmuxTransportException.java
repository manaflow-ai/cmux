package com.cmux.raw;

public final class CmuxTransportException extends CmuxException {
    private static final long serialVersionUID = 1L;

    public CmuxTransportException(String message, Throwable cause) {
        super(message, cause);
    }

    public CmuxTransportException(String message) {
        super(message);
    }
}
