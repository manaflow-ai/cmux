// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class JournalFrontendEventResult implements WireValue {

    private JournalFrontendEventResult(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    public Boolean committed() { return true; }

    public static JournalFrontendEventResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "JournalFrontendEventResult");
        Builder builder = builder();
        Object rawCommitted = Wire.required(object, "committed");
        ProtocolSupport.literal(rawCommitted, true, "JournalFrontendEventResult.committed");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "committed", true);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof JournalFrontendEventResult that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "JournalFrontendEventResult" + toWire(); }

    public static final class Builder {

        public JournalFrontendEventResult build() { return new JournalFrontendEventResult(this); }
    }
}
