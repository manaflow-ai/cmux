// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockWaits implements WireValue {
    private final UInt64 dropped;
    private final UInt64 longWaits;
    private final List<ServerStatsLockWait> recent;

    private ServerStatsLockWaits(Builder builder) {
        if (!builder.droppedSet) throw new IllegalArgumentException("dropped is required");
        this.dropped = Wire.nonNull(builder.dropped, "dropped");
        if (!builder.longWaitsSet) throw new IllegalArgumentException("long_waits is required");
        this.longWaits = Wire.nonNull(builder.longWaits, "long_waits");
        if (!builder.recentSet) throw new IllegalArgumentException("recent is required");
        this.recent = List.copyOf(Wire.nonNull(builder.recent, "recent"));
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 dropped() { return dropped; }
    public UInt64 longWaits() { return longWaits; }
    public List<ServerStatsLockWait> recent() { return recent; }

    public static ServerStatsLockWaits fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockWaits");
        Builder builder = builder();
        Object rawDropped = Wire.required(object, "dropped");
        builder.dropped(Wire.uint64(rawDropped, "ServerStatsLockWaits.dropped"));
        Object rawLongWaits = Wire.required(object, "long_waits");
        builder.longWaits(Wire.uint64(rawLongWaits, "ServerStatsLockWaits.long_waits"));
        Object rawRecent = Wire.required(object, "recent");
        builder.recent(Wire.array(rawRecent, "ServerStatsLockWaits.recent", item -> ServerStatsLockWait.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dropped", dropped);
        Wire.put(object, "long_waits", longWaits);
        Wire.put(object, "recent", recent);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockWaits that)) return false;
        return Objects.equals(dropped, that.dropped) && Objects.equals(longWaits, that.longWaits) && Objects.equals(recent, that.recent);
    }

    @Override
    public int hashCode() { return Objects.hash(dropped, longWaits, recent); }

    @Override
    public String toString() { return "ServerStatsLockWaits" + toWire(); }

    public static final class Builder {
        private UInt64 dropped;
        private boolean droppedSet;
        private UInt64 longWaits;
        private boolean longWaitsSet;
        private List<ServerStatsLockWait> recent;
        private boolean recentSet;

        public Builder dropped(UInt64 value) {
            this.dropped = value;
            this.droppedSet = true;
            return this;
        }
        public Builder longWaits(UInt64 value) {
            this.longWaits = value;
            this.longWaitsSet = true;
            return this;
        }
        public Builder recent(List<ServerStatsLockWait> value) {
            this.recent = value;
            this.recentSet = true;
            return this;
        }
        public ServerStatsLockWaits build() { return new ServerStatsLockWaits(this); }
    }
}
