// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ColumnPin implements WireValue {
    private final String edge;
    private final String mode;

    private ColumnPin(Builder builder) {
        if (!builder.edgeSet) throw new IllegalArgumentException("edge is required");
        this.edge = Wire.nonNull(builder.edge, "edge");
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
    }

    public static Builder builder() { return new Builder(); }

    public String edge() { return edge; }
    public String mode() { return mode; }

    public static ColumnPin fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ColumnPin");
        Builder builder = builder();
        Object rawEdge = Wire.required(object, "edge");
        builder.edge(Wire.string(rawEdge, "ColumnPin.edge"));
        Object rawMode = Wire.required(object, "mode");
        builder.mode(Wire.string(rawMode, "ColumnPin.mode"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "edge", edge);
        Wire.put(object, "mode", mode);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ColumnPin that)) return false;
        return Objects.equals(edge, that.edge) && Objects.equals(mode, that.mode);
    }

    @Override
    public int hashCode() { return Objects.hash(edge, mode); }

    @Override
    public String toString() { return "ColumnPin" + toWire(); }

    public static final class Builder {
        private String edge;
        private boolean edgeSet;
        private String mode;
        private boolean modeSet;

        public Builder edge(String value) {
            this.edge = value;
            this.edgeSet = true;
            return this;
        }
        public Builder mode(String value) {
            this.mode = value;
            this.modeSet = true;
            return this;
        }
        public ColumnPin build() { return new ColumnPin(this); }
    }
}
