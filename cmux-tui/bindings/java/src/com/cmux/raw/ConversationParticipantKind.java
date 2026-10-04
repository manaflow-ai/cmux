// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ConversationParticipantKind implements WireEnum {
    HUMAN("human"),
    AGENT("agent");

    private final Object wireValue;

    ConversationParticipantKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ConversationParticipantKind fromWire(Object value) {
        for (ConversationParticipantKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ConversationParticipantKind value " + value, null);
    }
}
