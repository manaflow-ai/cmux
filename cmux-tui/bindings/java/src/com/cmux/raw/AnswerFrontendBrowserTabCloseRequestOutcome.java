// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum AnswerFrontendBrowserTabCloseRequestOutcome implements WireEnum {
    CLOSING("closing"),
    CANCELLED("cancelled");

    private final Object wireValue;

    AnswerFrontendBrowserTabCloseRequestOutcome(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static AnswerFrontendBrowserTabCloseRequestOutcome fromWire(Object value) {
        for (AnswerFrontendBrowserTabCloseRequestOutcome candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown AnswerFrontendBrowserTabCloseRequestOutcome value " + value, null);
    }
}
