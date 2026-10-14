// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ConversationThreadStatus implements WireEnum {
    OPEN("open"),
    RESOLVED("resolved");

    private final Object wireValue;

    ConversationThreadStatus(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ConversationThreadStatus fromWire(Object value) {
        for (ConversationThreadStatus candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ConversationThreadStatus value " + value, null);
    }
}
