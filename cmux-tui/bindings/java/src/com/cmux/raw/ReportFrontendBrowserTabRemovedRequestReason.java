// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum ReportFrontendBrowserTabRemovedRequestReason implements WireEnum {
    ANSWERED("answered"),
    USER_CLOSED("user_closed"),
    PAGE_CLOSED("page_closed"),
    EXTENSION("extension");

    private final Object wireValue;

    ReportFrontendBrowserTabRemovedRequestReason(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ReportFrontendBrowserTabRemovedRequestReason fromWire(Object value) {
        for (ReportFrontendBrowserTabRemovedRequestReason candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown ReportFrontendBrowserTabRemovedRequestReason value " + value, null);
    }
}
