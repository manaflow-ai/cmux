package com.cmux.raw;

public class CmuxException extends Exception {
    private static final long serialVersionUID = 1L;

    public CmuxException(String message) {
        super(message);
    }

    public CmuxException(String message, Throwable cause) {
        super(message, cause);
    }
}
