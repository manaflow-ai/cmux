// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PresenceHighlight implements WireValue {
    private final PresenceAnchor end;
    private final PresenceHighlightMode mode;
    private final PresenceAnchor start;

    private PresenceHighlight(Builder builder) {
        if (!builder.endSet) throw new IllegalArgumentException("end is required");
        this.end = Wire.nonNull(builder.end, "end");
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
        if (!builder.startSet) throw new IllegalArgumentException("start is required");
        this.start = Wire.nonNull(builder.start, "start");
    }

    public static Builder builder() { return new Builder(); }

    public PresenceAnchor end() { return end; }
    public PresenceHighlightMode mode() { return mode; }
    public PresenceAnchor start() { return start; }

    public static PresenceHighlight fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PresenceHighlight");
        Builder builder = builder();
        Object rawEnd = Wire.required(object, "end");
        builder.end(PresenceAnchor.fromWire(rawEnd));
        Object rawMode = Wire.required(object, "mode");
        builder.mode(PresenceHighlightMode.fromWire(rawMode));
        Object rawStart = Wire.required(object, "start");
        builder.start(PresenceAnchor.fromWire(rawStart));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "end", end);
        Wire.put(object, "mode", mode);
        Wire.put(object, "start", start);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PresenceHighlight that)) return false;
        return Objects.equals(end, that.end) && Objects.equals(mode, that.mode) && Objects.equals(start, that.start);
    }

    @Override
    public int hashCode() { return Objects.hash(end, mode, start); }

    @Override
    public String toString() { return "PresenceHighlight" + toWire(); }

    public static final class Builder {
        private PresenceAnchor end;
        private boolean endSet;
        private PresenceHighlightMode mode;
        private boolean modeSet;
        private PresenceAnchor start;
        private boolean startSet;

        public Builder end(PresenceAnchor value) {
            this.end = value;
            this.endSet = true;
            return this;
        }
        public Builder mode(PresenceHighlightMode value) {
            this.mode = value;
            this.modeSet = true;
            return this;
        }
        public Builder start(PresenceAnchor value) {
            this.start = value;
            this.startSet = true;
            return this;
        }
        public PresenceHighlight build() { return new PresenceHighlight(this); }
    }
}
