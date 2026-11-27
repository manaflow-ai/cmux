// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ProgramStatusState implements WireEnum {
    WORKING("working"),
    BLOCKED("blocked"),
    ERROR("error"),
    DONE("done");

    private final Object wireValue;

    ProgramStatusState(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ProgramStatusState fromWire(Object value) {
        for (ProgramStatusState candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ProgramStatusState value " + value, null);
    }
}
