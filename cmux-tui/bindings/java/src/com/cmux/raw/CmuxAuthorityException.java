package com.cmux;

/** The client was not configured for the authority required by a command. */
public final class CmuxAuthorityException extends CmuxException {
    private static final long serialVersionUID = 1L;

    public CmuxAuthorityException(String message) {
        super(message);
    }
}
