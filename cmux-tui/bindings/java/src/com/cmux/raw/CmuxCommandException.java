package com.cmux.raw;

public final class CmuxCommandException extends CmuxException {
    private static final long serialVersionUID = 1L;
    private final String serverMessage;
    @SuppressWarnings("serial")
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
