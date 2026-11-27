// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HistorySearchRange implements WireValue {
    private final long end;
    private final long start;

    private HistorySearchRange(Builder builder) {
        if (!builder.endSet) throw new IllegalArgumentException("end is required");
        this.end = builder.end;
        if (!builder.startSet) throw new IllegalArgumentException("start is required");
        this.start = builder.start;
    }

    public static Builder builder() { return new Builder(); }

    public long end() { return end; }
    public long start() { return start; }

    public static HistorySearchRange fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HistorySearchRange");
        Builder builder = builder();
        Object rawEnd = Wire.required(object, "end");
        builder.end(Wire.uint32(rawEnd, "HistorySearchRange.end"));
        Object rawStart = Wire.required(object, "start");
        builder.start(Wire.uint32(rawStart, "HistorySearchRange.start"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "end", end);
        Wire.put(object, "start", start);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HistorySearchRange that)) return false;
        return Objects.equals(end, that.end) && Objects.equals(start, that.start);
    }

    @Override
    public int hashCode() { return Objects.hash(end, start); }

    @Override
    public String toString() { return "HistorySearchRange" + toWire(); }

    public static final class Builder {
        private Long end;
        private boolean endSet;
        private Long start;
        private boolean startSet;

        public Builder end(long value) {
            this.end = value;
            this.endSet = true;
            return this;
        }
        public Builder start(long value) {
            this.start = value;
            this.startSet = true;
            return this;
        }
        public HistorySearchRange build() { return new HistorySearchRange(this); }
    }
}
