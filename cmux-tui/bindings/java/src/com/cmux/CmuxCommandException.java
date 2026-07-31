package com.cmux;

public final class CmuxCommandException extends CmuxException {
    private final String serverMessage;
    private final Object commandId;
    private final String errorCode;
    private final CmuxErrorDelivery errorDelivery;

    public CmuxCommandException(String serverMessage, Object commandId) {
        this(serverMessage, commandId, null, null);
    }

    public CmuxCommandException(
        String serverMessage,
        Object commandId,
        CmuxErrorDelivery errorDelivery
    ) {
        this(serverMessage, commandId, null, errorDelivery);
    }

    public CmuxCommandException(
        String serverMessage,
        Object commandId,
        String errorCode,
        CmuxErrorDelivery errorDelivery
    ) {
        super(serverMessage);
        this.serverMessage = serverMessage;
        this.commandId = commandId;
        this.errorCode = errorCode;
        this.errorDelivery = errorDelivery;
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

    public CmuxErrorDelivery errorDelivery() {
        return errorDelivery;
    }
}
