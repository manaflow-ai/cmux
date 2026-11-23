// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsDiskSegmentKind implements WireValue {
    private final String kind;
    private final UInt64 segments;

    private ServerStatsDiskSegmentKind(Builder builder) {
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.segmentsSet) throw new IllegalArgumentException("segments is required");
        this.segments = Wire.nonNull(builder.segments, "segments");
    }

    public static Builder builder() { return new Builder(); }

    public String kind() { return kind; }
    public UInt64 segments() { return segments; }

    public static ServerStatsDiskSegmentKind fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsDiskSegmentKind");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ServerStatsDiskSegmentKind.kind"));
        Object rawSegments = Wire.required(object, "segments");
        builder.segments(Wire.uint64(rawSegments, "ServerStatsDiskSegmentKind.segments"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", kind);
        Wire.put(object, "segments", segments);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsDiskSegmentKind that)) return false;
        return Objects.equals(kind, that.kind) && Objects.equals(segments, that.segments);
    }

    @Override
    public int hashCode() { return Objects.hash(kind, segments); }

    @Override
    public String toString() { return "ServerStatsDiskSegmentKind" + toWire(); }

    public static final class Builder {
        private String kind;
        private boolean kindSet;
        private UInt64 segments;
        private boolean segmentsSet;

        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder segments(UInt64 value) {
            this.segments = value;
            this.segmentsSet = true;
            return this;
        }
        public ServerStatsDiskSegmentKind build() { return new ServerStatsDiskSegmentKind(this); }
    }
}
