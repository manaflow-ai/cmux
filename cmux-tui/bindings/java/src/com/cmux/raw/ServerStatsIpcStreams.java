// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsIpcStreams implements WireValue {
    private final UInt64 open_;
    private final UInt64 opened;
    private final UInt64 peak;

    private ServerStatsIpcStreams(Builder builder) {
        if (!builder.open_Set) throw new IllegalArgumentException("open is required");
        this.open_ = Wire.nonNull(builder.open_, "open");
        if (!builder.openedSet) throw new IllegalArgumentException("opened is required");
        this.opened = Wire.nonNull(builder.opened, "opened");
        if (!builder.peakSet) throw new IllegalArgumentException("peak is required");
        this.peak = Wire.nonNull(builder.peak, "peak");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 open_() { return open_; }
    public UInt64 opened() { return opened; }
    public UInt64 peak() { return peak; }

    public static ServerStatsIpcStreams fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsIpcStreams");
        Builder builder = builder();
        Object rawOpen = Wire.required(object, "open");
        builder.open_(Wire.uint64(rawOpen, "ServerStatsIpcStreams.open"));
        Object rawOpened = Wire.required(object, "opened");
        builder.opened(Wire.uint64(rawOpened, "ServerStatsIpcStreams.opened"));
        Object rawPeak = Wire.required(object, "peak");
        builder.peak(Wire.uint64(rawPeak, "ServerStatsIpcStreams.peak"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "open", open_);
        Wire.put(object, "opened", opened);
        Wire.put(object, "peak", peak);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsIpcStreams that)) return false;
        return Objects.equals(open_, that.open_) && Objects.equals(opened, that.opened) && Objects.equals(peak, that.peak);
    }

    @Override
    public int hashCode() { return Objects.hash(open_, opened, peak); }

    @Override
    public String toString() { return "ServerStatsIpcStreams" + toWire(); }

    public static final class Builder {
        private UInt64 open_;
        private boolean open_Set;
        private UInt64 opened;
        private boolean openedSet;
        private UInt64 peak;
        private boolean peakSet;

        public Builder open_(UInt64 value) {
            this.open_ = value;
            this.open_Set = true;
            return this;
        }
        public Builder opened(UInt64 value) {
            this.opened = value;
            this.openedSet = true;
            return this;
        }
        public Builder peak(UInt64 value) {
            this.peak = value;
            this.peakSet = true;
            return this;
        }
        public ServerStatsIpcStreams build() { return new ServerStatsIpcStreams(this); }
    }
}
