// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum FrontendBrowserTabCloseSettledEventOutcome implements WireEnum {
    REMOVED("removed"),
    CANCELLED("cancelled"),
    OWNER_GONE("owner_gone"),
    TIMED_OUT("timed_out");

    private final Object wireValue;

    FrontendBrowserTabCloseSettledEventOutcome(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static FrontendBrowserTabCloseSettledEventOutcome fromWire(Object value) {
        for (FrontendBrowserTabCloseSettledEventOutcome candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown FrontendBrowserTabCloseSettledEventOutcome value " + value, null);
    }
}
