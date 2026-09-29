// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-to-split request. Protocol v12; authority: control. */
public final class MoveTabToSplitRequest implements WireValue {
    private final String edge;
    private final UInt64 pane;
    private final Field<Double> ratio;
    private final UInt64 surface;
    private final Field<String> transaction;

    private MoveTabToSplitRequest(Builder builder) {
        if (!builder.edgeSet) throw new IllegalArgumentException("edge is required");
        this.edge = Wire.nonNull(builder.edge, "edge");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.ratio = builder.ratio;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public String edge() { return edge; }
    public UInt64 pane() { return pane; }
    public Field<Double> ratio() { return ratio; }
    public UInt64 surface() { return surface; }
    public Field<String> transaction() { return transaction; }

    public static MoveTabToSplitRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabToSplitRequest");
        Builder builder = builder();
        Object rawEdge = Wire.required(object, "edge");
        builder.edge(Wire.string(rawEdge, "MoveTabToSplitRequest.edge"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "MoveTabToSplitRequest.pane"));
        Object rawRatio = Wire.optional(object, "ratio");
        if (!Wire.isMissing(rawRatio)) {
            builder.ratio(rawRatio == null ? null : Wire.float64(rawRatio, "MoveTabToSplitRequest.ratio"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "MoveTabToSplitRequest.surface"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "MoveTabToSplitRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "edge", edge);
        Wire.put(object, "pane", pane);
        Wire.put(object, "ratio", ratio);
        Wire.put(object, "surface", surface);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabToSplitRequest that)) return false;
        return Objects.equals(edge, that.edge) && Objects.equals(pane, that.pane) && Objects.equals(ratio, that.ratio) && Objects.equals(surface, that.surface) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(edge, pane, ratio, surface, transaction); }

    @Override
    public String toString() { return "MoveTabToSplitRequest" + toWire(); }

    public static final class Builder {
        private String edge;
        private boolean edgeSet;
        private UInt64 pane;
        private boolean paneSet;
        private Field<Double> ratio = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> transaction = Field.omitted();

        public Builder edge(String value) {
            this.edge = value;
            this.edgeSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder ratio(Double value) {
            this.ratio = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public MoveTabToSplitRequest build() { return new MoveTabToSplitRequest(this); }
    }
}
