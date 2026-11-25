// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HostReplicaSeal implements WireValue {
    private final String sourceKey;
    private final List<String> viewers;

    private HostReplicaSeal(Builder builder) {
        if (!builder.sourceKeySet) throw new IllegalArgumentException("source_key is required");
        this.sourceKey = Wire.nonNull(builder.sourceKey, "source_key");
        if (!builder.viewersSet) throw new IllegalArgumentException("viewers is required");
        this.viewers = List.copyOf(Wire.nonNull(builder.viewers, "viewers"));
    }

    public static Builder builder() { return new Builder(); }

    public String sourceKey() { return sourceKey; }
    public List<String> viewers() { return viewers; }

    public static HostReplicaSeal fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HostReplicaSeal");
        Builder builder = builder();
        Object rawSourceKey = Wire.required(object, "source_key");
        builder.sourceKey(Wire.string(rawSourceKey, "HostReplicaSeal.source_key"));
        Object rawViewers = Wire.required(object, "viewers");
        builder.viewers(Wire.array(rawViewers, "HostReplicaSeal.viewers", item -> Wire.string(item, "HostReplicaSeal.viewers item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "source_key", sourceKey);
        Wire.put(object, "viewers", viewers);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HostReplicaSeal that)) return false;
        return Objects.equals(sourceKey, that.sourceKey) && Objects.equals(viewers, that.viewers);
    }

    @Override
    public int hashCode() { return Objects.hash(sourceKey, viewers); }

    @Override
    public String toString() { return "HostReplicaSeal" + toWire(); }

    public static final class Builder {
        private String sourceKey;
        private boolean sourceKeySet;
        private List<String> viewers;
        private boolean viewersSet;

        public Builder sourceKey(String value) {
            this.sourceKey = value;
            this.sourceKeySet = true;
            return this;
        }
        public Builder viewers(List<String> value) {
            this.viewers = value;
            this.viewersSet = true;
            return this;
        }
        public HostReplicaSeal build() { return new HostReplicaSeal(this); }
    }
}
