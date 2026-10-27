// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BrowserRuntimeStopResult implements WireValue {

    private BrowserRuntimeStopResult(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    public Boolean stopped() { return true; }

    public static BrowserRuntimeStopResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserRuntimeStopResult");
        Builder builder = builder();
        Object rawStopped = Wire.required(object, "stopped");
        ProtocolSupport.literal(rawStopped, true, "BrowserRuntimeStopResult.stopped");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "stopped", true);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserRuntimeStopResult that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "BrowserRuntimeStopResult" + toWire(); }

    public static final class Builder {

        public BrowserRuntimeStopResult build() { return new BrowserRuntimeStopResult(this); }
    }
}
