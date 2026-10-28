// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum MachineCatalogStatus implements WireEnum {
    RUNNING("running"),
    CONNECTING("connecting"),
    UNAVAILABLE("unavailable"),
    SLEEPING("sleeping"),
    STOPPED("stopped");

    private final Object wireValue;

    MachineCatalogStatus(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static MachineCatalogStatus fromWire(Object value) {
        for (MachineCatalogStatus candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown MachineCatalogStatus value " + value, null);
    }
}
