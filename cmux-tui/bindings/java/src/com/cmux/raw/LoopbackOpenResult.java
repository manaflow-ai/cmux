// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LoopbackOpenResult implements WireValue {
    private final String address;
    private final UInt64 stream;
    private final UInt64 window;

    private LoopbackOpenResult(Builder builder) {
        if (!builder.addressSet) throw new IllegalArgumentException("address is required");
        this.address = Wire.nonNull(builder.address, "address");
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = Wire.nonNull(builder.stream, "stream");
        if (!builder.windowSet) throw new IllegalArgumentException("window is required");
        this.window = Wire.nonNull(builder.window, "window");
    }

    public static Builder builder() { return new Builder(); }

    public String address() { return address; }
    public UInt64 stream() { return stream; }
    public UInt64 window() { return window; }

    public static LoopbackOpenResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackOpenResult");
        Builder builder = builder();
        Object rawAddress = Wire.required(object, "address");
        builder.address(Wire.string(rawAddress, "LoopbackOpenResult.address"));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint64(rawStream, "LoopbackOpenResult.stream"));
        Object rawWindow = Wire.required(object, "window");
        builder.window(Wire.uint64(rawWindow, "LoopbackOpenResult.window"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "address", address);
        Wire.put(object, "stream", stream);
        Wire.put(object, "window", window);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackOpenResult that)) return false;
        return Objects.equals(address, that.address) && Objects.equals(stream, that.stream) && Objects.equals(window, that.window);
    }

    @Override
    public int hashCode() { return Objects.hash(address, stream, window); }

    @Override
    public String toString() { return "LoopbackOpenResult" + toWire(); }

    public static final class Builder {
        private String address;
        private boolean addressSet;
        private UInt64 stream;
        private boolean streamSet;
        private UInt64 window;
        private boolean windowSet;

        public Builder address(String value) {
            this.address = value;
            this.addressSet = true;
            return this;
        }
        public Builder stream(UInt64 value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public Builder window(UInt64 value) {
            this.window = value;
            this.windowSet = true;
            return this;
        }
        public LoopbackOpenResult build() { return new LoopbackOpenResult(this); }
    }
}
