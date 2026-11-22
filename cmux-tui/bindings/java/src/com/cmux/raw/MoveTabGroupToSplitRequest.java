// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-group-to-split request. Protocol v12; authority: control. */
public final class MoveTabGroupToSplitRequest implements WireValue {
    private final String edge;
    private final String group;
    private final Object pane;
    private final Field<Double> ratio;
    private final Field<String> transaction;

    private MoveTabGroupToSplitRequest(Builder builder) {
        if (!builder.edgeSet) throw new IllegalArgumentException("edge is required");
        this.edge = Wire.nonNull(builder.edge, "edge");
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.ratio = builder.ratio;
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public String edge() { return edge; }
    public String group() { return group; }
    public Object pane() { return pane; }
    public Field<Double> ratio() { return ratio; }
    public Field<String> transaction() { return transaction; }

    public static MoveTabGroupToSplitRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabGroupToSplitRequest");
        Builder builder = builder();
        Object rawEdge = Wire.required(object, "edge");
        builder.edge(Wire.string(rawEdge, "MoveTabGroupToSplitRequest.edge"));
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "MoveTabGroupToSplitRequest.group"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.immutableJson(rawPane));
        Object rawRatio = Wire.optional(object, "ratio");
        if (!Wire.isMissing(rawRatio)) {
            builder.ratio(rawRatio == null ? null : Wire.float64(rawRatio, "MoveTabGroupToSplitRequest.ratio"));
        }
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "MoveTabGroupToSplitRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "edge", edge);
        Wire.put(object, "group", group);
        Wire.put(object, "pane", pane);
        Wire.put(object, "ratio", ratio);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabGroupToSplitRequest that)) return false;
        return Objects.equals(edge, that.edge) && Objects.equals(group, that.group) && Objects.equals(pane, that.pane) && Objects.equals(ratio, that.ratio) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(edge, group, pane, ratio, transaction); }

    @Override
    public String toString() { return "MoveTabGroupToSplitRequest" + toWire(); }

    public static final class Builder {
        private String edge;
        private boolean edgeSet;
        private String group;
        private boolean groupSet;
        private Object pane;
        private boolean paneSet;
        private Field<Double> ratio = Field.omitted();
        private Field<String> transaction = Field.omitted();

        public Builder edge(String value) {
            this.edge = value;
            this.edgeSet = true;
            return this;
        }
        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder pane(Object value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder ratio(Double value) {
            this.ratio = Field.ofNullable(value);
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public MoveTabGroupToSplitRequest build() { return new MoveTabGroupToSplitRequest(this); }
    }
}
