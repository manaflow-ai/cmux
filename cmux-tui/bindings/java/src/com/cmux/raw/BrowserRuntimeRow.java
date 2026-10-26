// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BrowserRuntimeRow implements WireValue {
    private final int port;
    private final UInt64 runtime;

    private BrowserRuntimeRow(Builder builder) {
        if (!builder.portSet) throw new IllegalArgumentException("port is required");
        this.port = builder.port;
        if (!builder.runtimeSet) throw new IllegalArgumentException("runtime is required");
        this.runtime = Wire.nonNull(builder.runtime, "runtime");
    }

    public static Builder builder() { return new Builder(); }

    public int port() { return port; }
    public UInt64 runtime() { return runtime; }

    public static BrowserRuntimeRow fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserRuntimeRow");
        Builder builder = builder();
        Object rawPort = Wire.required(object, "port");
        builder.port(Wire.uint16(rawPort, "BrowserRuntimeRow.port"));
        Object rawRuntime = Wire.required(object, "runtime");
        builder.runtime(Wire.uint64(rawRuntime, "BrowserRuntimeRow.runtime"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "port", port);
        Wire.put(object, "runtime", runtime);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserRuntimeRow that)) return false;
        return Objects.equals(port, that.port) && Objects.equals(runtime, that.runtime);
    }

    @Override
    public int hashCode() { return Objects.hash(port, runtime); }

    @Override
    public String toString() { return "BrowserRuntimeRow" + toWire(); }

    public static final class Builder {
        private Integer port;
        private boolean portSet;
        private UInt64 runtime;
        private boolean runtimeSet;

        public Builder port(int value) {
            this.port = value;
            this.portSet = true;
            return this;
        }
        public Builder runtime(UInt64 value) {
            this.runtime = value;
            this.runtimeSet = true;
            return this;
        }
        public BrowserRuntimeRow build() { return new BrowserRuntimeRow(this); }
    }
}
