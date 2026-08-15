package com.cmux.raw;

/**
 * Unchecked protocol-shape error. Transport and command failures remain
 * checked because callers can recover from them; malformed server data is a
 * broken protocol contract.
 */
public final class CmuxDecodeException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public CmuxDecodeException(String message, Throwable cause) {
        super(message, cause);
    }
}
