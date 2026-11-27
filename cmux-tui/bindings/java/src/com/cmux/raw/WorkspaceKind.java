// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum WorkspaceKind implements WireEnum {
    NORMAL("normal"),
    HOME("home"),
    APP("app");

    private final Object wireValue;

    WorkspaceKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static WorkspaceKind fromWire(Object value) {
        for (WorkspaceKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown WorkspaceKind value " + value, null);
    }
}
