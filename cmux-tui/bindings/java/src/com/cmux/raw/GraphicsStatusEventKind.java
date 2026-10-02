// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum GraphicsStatusEventKind implements WireEnum {
    KITTY_IMAGE_BUDGET_WORKER_START_FAILED("kitty-image-budget-worker-start-failed"),
    KITTY_IMAGE_BUDGET_UPDATE_FAILED("kitty-image-budget-update-failed"),
    CELL_PIXEL_UPDATE_RETRIES_EXHAUSTED("cell-pixel-update-retries-exhausted");

    private final Object wireValue;

    GraphicsStatusEventKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static GraphicsStatusEventKind fromWire(Object value) {
        for (GraphicsStatusEventKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown GraphicsStatusEventKind value " + value, null);
    }
}
