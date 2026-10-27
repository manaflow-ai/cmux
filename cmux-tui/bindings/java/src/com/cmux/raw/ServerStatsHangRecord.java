// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsHangRecord implements WireValue {
    private final UInt64 durationMs;
    private final UInt64 sequence;
    private final String span;

    private ServerStatsHangRecord(Builder builder) {
        if (!builder.durationMsSet) throw new IllegalArgumentException("duration_ms is required");
        this.durationMs = Wire.nonNull(builder.durationMs, "duration_ms");
        if (!builder.sequenceSet) throw new IllegalArgumentException("sequence is required");
        this.sequence = Wire.nonNull(builder.sequence, "sequence");
        if (!builder.spanSet) throw new IllegalArgumentException("span is required");
        this.span = Wire.nonNull(builder.span, "span");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 durationMs() { return durationMs; }
    public UInt64 sequence() { return sequence; }
    public String span() { return span; }

    public static ServerStatsHangRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsHangRecord");
        Builder builder = builder();
        Object rawDurationMs = Wire.required(object, "duration_ms");
        builder.durationMs(Wire.uint64(rawDurationMs, "ServerStatsHangRecord.duration_ms"));
        Object rawSequence = Wire.required(object, "sequence");
        builder.sequence(Wire.uint64(rawSequence, "ServerStatsHangRecord.sequence"));
        Object rawSpan = Wire.required(object, "span");
        builder.span(Wire.string(rawSpan, "ServerStatsHangRecord.span"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "duration_ms", durationMs);
        Wire.put(object, "sequence", sequence);
        Wire.put(object, "span", span);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsHangRecord that)) return false;
        return Objects.equals(durationMs, that.durationMs) && Objects.equals(sequence, that.sequence) && Objects.equals(span, that.span);
    }

    @Override
    public int hashCode() { return Objects.hash(durationMs, sequence, span); }

    @Override
    public String toString() { return "ServerStatsHangRecord" + toWire(); }

    public static final class Builder {
        private UInt64 durationMs;
        private boolean durationMsSet;
        private UInt64 sequence;
        private boolean sequenceSet;
        private String span;
        private boolean spanSet;

        public Builder durationMs(UInt64 value) {
            this.durationMs = value;
            this.durationMsSet = true;
            return this;
        }
        public Builder sequence(UInt64 value) {
            this.sequence = value;
            this.sequenceSet = true;
            return this;
        }
        public Builder span(String value) {
            this.span = value;
            this.spanSet = true;
            return this;
        }
        public ServerStatsHangRecord build() { return new ServerStatsHangRecord(this); }
    }
}
