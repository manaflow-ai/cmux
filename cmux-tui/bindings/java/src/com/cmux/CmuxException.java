package com.cmux;

public class CmuxException extends Exception {
    public CmuxException(String message) {
        super(message);
    }

    public CmuxException(String message, Throwable cause) {
        super(message, cause);
    }
}
