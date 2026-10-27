// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LoopbackLimits implements WireValue {
    private final UInt64 daemonWindow;
    private final UInt64 frameBytes;
    private final UInt64 perClient;
    private final UInt64 total;

    private LoopbackLimits(Builder builder) {
        if (!builder.daemonWindowSet) throw new IllegalArgumentException("daemon_window is required");
        this.daemonWindow = Wire.nonNull(builder.daemonWindow, "daemon_window");
        if (!builder.frameBytesSet) throw new IllegalArgumentException("frame_bytes is required");
        this.frameBytes = Wire.nonNull(builder.frameBytes, "frame_bytes");
        if (!builder.perClientSet) throw new IllegalArgumentException("per_client is required");
        this.perClient = Wire.nonNull(builder.perClient, "per_client");
        if (!builder.totalSet) throw new IllegalArgumentException("total is required");
        this.total = Wire.nonNull(builder.total, "total");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 daemonWindow() { return daemonWindow; }
    public UInt64 frameBytes() { return frameBytes; }
    public UInt64 perClient() { return perClient; }
    public UInt64 total() { return total; }

    public static LoopbackLimits fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackLimits");
        Builder builder = builder();
        Object rawDaemonWindow = Wire.required(object, "daemon_window");
        builder.daemonWindow(Wire.uint64(rawDaemonWindow, "LoopbackLimits.daemon_window"));
        Object rawFrameBytes = Wire.required(object, "frame_bytes");
        builder.frameBytes(Wire.uint64(rawFrameBytes, "LoopbackLimits.frame_bytes"));
        Object rawPerClient = Wire.required(object, "per_client");
        builder.perClient(Wire.uint64(rawPerClient, "LoopbackLimits.per_client"));
        Object rawTotal = Wire.required(object, "total");
        builder.total(Wire.uint64(rawTotal, "LoopbackLimits.total"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "daemon_window", daemonWindow);
        Wire.put(object, "frame_bytes", frameBytes);
        Wire.put(object, "per_client", perClient);
        Wire.put(object, "total", total);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackLimits that)) return false;
        return Objects.equals(daemonWindow, that.daemonWindow) && Objects.equals(frameBytes, that.frameBytes) && Objects.equals(perClient, that.perClient) && Objects.equals(total, that.total);
    }

    @Override
    public int hashCode() { return Objects.hash(daemonWindow, frameBytes, perClient, total); }

    @Override
    public String toString() { return "LoopbackLimits" + toWire(); }

    public static final class Builder {
        private UInt64 daemonWindow;
        private boolean daemonWindowSet;
        private UInt64 frameBytes;
        private boolean frameBytesSet;
        private UInt64 perClient;
        private boolean perClientSet;
        private UInt64 total;
        private boolean totalSet;

        public Builder daemonWindow(UInt64 value) {
            this.daemonWindow = value;
            this.daemonWindowSet = true;
            return this;
        }
        public Builder frameBytes(UInt64 value) {
            this.frameBytes = value;
            this.frameBytesSet = true;
            return this;
        }
        public Builder perClient(UInt64 value) {
            this.perClient = value;
            this.perClientSet = true;
            return this;
        }
        public Builder total(UInt64 value) {
            this.total = value;
            this.totalSet = true;
            return this;
        }
        public LoopbackLimits build() { return new LoopbackLimits(this); }
    }
}
