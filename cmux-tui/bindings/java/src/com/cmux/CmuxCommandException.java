package com.cmux;

public final class CmuxCommandException extends CmuxException {
    private final String serverMessage;
    private final Object commandId;

    public CmuxCommandException(String serverMessage, Object commandId) {
        super(serverMessage);
        this.serverMessage = serverMessage;
        this.commandId = commandId;
    }

    public String serverMessage() {
        return serverMessage;
    }

    public Object commandId() {
        return commandId;
    }
}
