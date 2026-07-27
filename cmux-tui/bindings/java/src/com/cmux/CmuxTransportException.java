package com.cmux;

public final class CmuxTransportException extends CmuxException {
    public CmuxTransportException(String message, Throwable cause) {
        super(message, cause);
    }

    public CmuxTransportException(String message) {
        super(message);
    }
}
