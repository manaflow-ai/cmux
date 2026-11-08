// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable pane-neighbor request. Protocol v6; authority: control. */
public final class PaneNeighborRequest implements WireValue {
    private final PaneDirection dir;
    private final UInt64 pane;

    private PaneNeighborRequest(Builder builder) {
        if (!builder.dirSet) throw new IllegalArgumentException("dir is required");
        this.dir = Wire.nonNull(builder.dir, "dir");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
    }

    public static Builder builder() { return new Builder(); }

    public PaneDirection dir() { return dir; }
    public UInt64 pane() { return pane; }

    public static PaneNeighborRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PaneNeighborRequest");
        Builder builder = builder();
        Object rawDir = Wire.required(object, "dir");
        builder.dir(PaneDirection.fromWire(rawDir));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "PaneNeighborRequest.pane"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dir", dir);
        Wire.put(object, "pane", pane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PaneNeighborRequest that)) return false;
        return Objects.equals(dir, that.dir) && Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(dir, pane); }

    @Override
    public String toString() { return "PaneNeighborRequest" + toWire(); }

    public static final class Builder {
        private PaneDirection dir;
        private boolean dirSet;
        private UInt64 pane;
        private boolean paneSet;

        public Builder dir(PaneDirection value) {
            this.dir = value;
            this.dirSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public PaneNeighborRequest build() { return new PaneNeighborRequest(this); }
    }
}
