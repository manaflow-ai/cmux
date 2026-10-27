// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum MachineCatalogOrigin implements WireEnum {
    CLOUD("cloud"),
    SSH("ssh"),
    SERVER("server");

    private final Object wireValue;

    MachineCatalogOrigin(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static MachineCatalogOrigin fromWire(Object value) {
        for (MachineCatalogOrigin candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown MachineCatalogOrigin value " + value, null);
    }
}
