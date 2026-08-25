// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ZoomPaneResult implements WireValue {
    private final UInt64 pane;
    private final boolean zoomed;
    private final UInt64 zoomedPane;

    private ZoomPaneResult(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.zoomedSet) throw new IllegalArgumentException("zoomed is required");
        this.zoomed = builder.zoomed;
        if (!builder.zoomedPaneSet) throw new IllegalArgumentException("zoomed_pane is required");
        this.zoomedPane = builder.zoomedPane;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }
    public boolean zoomed() { return zoomed; }
    public UInt64 zoomedPane() { return zoomedPane; }

    public static ZoomPaneResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ZoomPaneResult");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "ZoomPaneResult.pane"));
        Object rawZoomed = Wire.required(object, "zoomed");
        builder.zoomed(Wire.bool(rawZoomed, "ZoomPaneResult.zoomed"));
        Object rawZoomedPane = Wire.required(object, "zoomed_pane");
        builder.zoomedPane(rawZoomedPane == null ? null : Wire.uint64(rawZoomedPane, "ZoomPaneResult.zoomed_pane"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        Wire.put(object, "zoomed", zoomed);
        Wire.put(object, "zoomed_pane", zoomedPane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ZoomPaneResult that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(zoomed, that.zoomed) && Objects.equals(zoomedPane, that.zoomedPane);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, zoomed, zoomedPane); }

    @Override
    public String toString() { return "ZoomPaneResult" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;
        private Boolean zoomed;
        private boolean zoomedSet;
        private UInt64 zoomedPane;
        private boolean zoomedPaneSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder zoomed(boolean value) {
            this.zoomed = value;
            this.zoomedSet = true;
            return this;
        }
        public Builder zoomedPane(UInt64 value) {
            this.zoomedPane = value;
            this.zoomedPaneSet = true;
            return this;
        }
        public ZoomPaneResult build() { return new ZoomPaneResult(this); }
    }
}
