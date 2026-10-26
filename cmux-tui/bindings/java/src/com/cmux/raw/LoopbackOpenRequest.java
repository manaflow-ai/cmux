// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable loopback-open request. Protocol v12; authority: local-admin. */
public final class LoopbackOpenRequest implements WireValue {
    private final String host;
    private final int port;
    private final UInt64 stream;
    private final Field<UInt64> window;

    private LoopbackOpenRequest(Builder builder) {
        if (!builder.hostSet) throw new IllegalArgumentException("host is required");
        this.host = Wire.nonNull(builder.host, "host");
        if (!builder.portSet) throw new IllegalArgumentException("port is required");
        this.port = builder.port;
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = Wire.nonNull(builder.stream, "stream");
        this.window = builder.window;
    }

    public static Builder builder() { return new Builder(); }

    public String host() { return host; }
    public int port() { return port; }
    public UInt64 stream() { return stream; }
    public Field<UInt64> window() { return window; }

    public static LoopbackOpenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackOpenRequest");
        Builder builder = builder();
        Object rawHost = Wire.required(object, "host");
        builder.host(Wire.string(rawHost, "LoopbackOpenRequest.host"));
        Object rawPort = Wire.required(object, "port");
        builder.port(Wire.uint16(rawPort, "LoopbackOpenRequest.port"));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint64(rawStream, "LoopbackOpenRequest.stream"));
        Object rawWindow = Wire.optional(object, "window");
        if (!Wire.isMissing(rawWindow)) {
            builder.window(rawWindow == null ? null : Wire.uint64(rawWindow, "LoopbackOpenRequest.window"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "host", host);
        Wire.put(object, "port", port);
        Wire.put(object, "stream", stream);
        Wire.put(object, "window", window);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackOpenRequest that)) return false;
        return Objects.equals(host, that.host) && Objects.equals(port, that.port) && Objects.equals(stream, that.stream) && Objects.equals(window, that.window);
    }

    @Override
    public int hashCode() { return Objects.hash(host, port, stream, window); }

    @Override
    public String toString() { return "LoopbackOpenRequest" + toWire(); }

    public static final class Builder {
        private String host;
        private boolean hostSet;
        private Integer port;
        private boolean portSet;
        private UInt64 stream;
        private boolean streamSet;
        private Field<UInt64> window = Field.omitted();

        public Builder host(String value) {
            this.host = value;
            this.hostSet = true;
            return this;
        }
        public Builder port(int value) {
            this.port = value;
            this.portSet = true;
            return this;
        }
        public Builder stream(UInt64 value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public Builder window(UInt64 value) {
            this.window = Field.ofNullable(value);
            return this;
        }
        public LoopbackOpenRequest build() { return new LoopbackOpenRequest(this); }
    }
}
