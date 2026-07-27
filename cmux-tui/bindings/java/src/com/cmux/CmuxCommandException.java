package com.cmux;

public final class CmuxCommandException extends CmuxException {
    private final String serverMessage;
    private final Object commandId;
    private final CmuxErrorDelivery errorDelivery;

    public CmuxCommandException(String serverMessage, Object commandId) {
        this(serverMessage, commandId, null);
    }

    public CmuxCommandException(
        String serverMessage,
        Object commandId,
        CmuxErrorDelivery errorDelivery
    ) {
        super(serverMessage);
        this.serverMessage = serverMessage;
        this.commandId = commandId;
        this.errorDelivery = errorDelivery;
    }

    public String serverMessage() {
        return serverMessage;
    }

    public Object commandId() {
        return commandId;
    }

    public CmuxErrorDelivery errorDelivery() {
        return errorDelivery;
    }
}
