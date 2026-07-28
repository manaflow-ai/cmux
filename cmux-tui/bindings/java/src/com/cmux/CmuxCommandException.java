package com.cmux;

public final class CmuxCommandException extends CmuxException {
    private static final long serialVersionUID = 1L;
    private final String serverMessage;
    @SuppressWarnings("serial")
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
