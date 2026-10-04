// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ConversationWorkStatus implements WireEnum {
    RUNNING("running"),
    DONE("done"),
    FAILED("failed"),
    WAITING("waiting");

    private final Object wireValue;

    ConversationWorkStatus(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ConversationWorkStatus fromWire(Object value) {
        for (ConversationWorkStatus candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ConversationWorkStatus value " + value, null);
    }
}
