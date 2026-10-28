// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ServerDiagnosticSiteEventFamily implements WireEnum {
    BLOCKING("blocking"),
    INVERSION("inversion"),
    HANG("hang");

    private final Object wireValue;

    ServerDiagnosticSiteEventFamily(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ServerDiagnosticSiteEventFamily fromWire(Object value) {
        for (ServerDiagnosticSiteEventFamily candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ServerDiagnosticSiteEventFamily value " + value, null);
    }
}
