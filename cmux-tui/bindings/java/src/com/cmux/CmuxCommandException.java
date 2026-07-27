package com.cmux;

public final class CmuxCommandException extends CmuxException {
    private final String serverMessage;
    private final Object commandId;
    private final String errorCode;

    public CmuxCommandException(String serverMessage, Object commandId) {
        this(serverMessage, commandId, null);
    }

    public CmuxCommandException(String serverMessage, Object commandId, String errorCode) {
        super(serverMessage);
        this.serverMessage = serverMessage;
        this.commandId = commandId;
        this.errorCode = errorCode;
    }

    public String serverMessage() {
        return serverMessage;
    }

    public Object commandId() {
        return commandId;
    }

    public String errorCode() {
        return errorCode;
    }
}
