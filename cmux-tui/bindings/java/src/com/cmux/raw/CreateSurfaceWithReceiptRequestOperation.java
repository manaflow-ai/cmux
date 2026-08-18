// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum CreateSurfaceWithReceiptRequestOperation implements WireEnum {
    NEW_TAB("new-tab"),
    RUN_COMMAND("run-command"),
    NEW_BROWSER_TAB("new-browser-tab"),
    NEW_WORKSPACE("new-workspace"),
    NEW_SCREEN("new-screen"),
    NEW_PANE("new-pane"),
    NEW_PANE_RIGHT("new-pane-right"),
    SPLIT_RIGHT("split-right"),
    SPLIT_DOWN("split-down");

    private final Object wireValue;

    CreateSurfaceWithReceiptRequestOperation(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static CreateSurfaceWithReceiptRequestOperation fromWire(Object value) {
        for (CreateSurfaceWithReceiptRequestOperation candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown CreateSurfaceWithReceiptRequestOperation value " + value, null);
    }
}
