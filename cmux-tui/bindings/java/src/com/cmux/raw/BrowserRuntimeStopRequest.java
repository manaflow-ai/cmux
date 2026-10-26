// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-runtime-stop request. Protocol v12; authority: local-admin. */
public final class BrowserRuntimeStopRequest implements WireValue {
    private final UInt64 runtime;

    private BrowserRuntimeStopRequest(Builder builder) {
        if (!builder.runtimeSet) throw new IllegalArgumentException("runtime is required");
        this.runtime = Wire.nonNull(builder.runtime, "runtime");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 runtime() { return runtime; }

    public static BrowserRuntimeStopRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserRuntimeStopRequest");
        Builder builder = builder();
        Object rawRuntime = Wire.required(object, "runtime");
        builder.runtime(Wire.uint64(rawRuntime, "BrowserRuntimeStopRequest.runtime"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "runtime", runtime);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserRuntimeStopRequest that)) return false;
        return Objects.equals(runtime, that.runtime);
    }

    @Override
    public int hashCode() { return Objects.hash(runtime); }

    @Override
    public String toString() { return "BrowserRuntimeStopRequest" + toWire(); }

    public static final class Builder {
        private UInt64 runtime;
        private boolean runtimeSet;

        public Builder runtime(UInt64 value) {
            this.runtime = value;
            this.runtimeSet = true;
            return this;
        }
        public BrowserRuntimeStopRequest build() { return new BrowserRuntimeStopRequest(this); }
    }
}
