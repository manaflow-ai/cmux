// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PaneNeighborResult implements WireValue {
    private final UInt64 pane;

    private PaneNeighborResult(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = builder.pane;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }

    public static PaneNeighborResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PaneNeighborResult");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "PaneNeighborResult.pane"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PaneNeighborResult that)) return false;
        return Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(pane); }

    @Override
    public String toString() { return "PaneNeighborResult" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public PaneNeighborResult build() { return new PaneNeighborResult(this); }
    }
}
