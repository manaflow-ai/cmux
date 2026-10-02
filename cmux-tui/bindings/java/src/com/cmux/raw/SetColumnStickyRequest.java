// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-column-sticky request. Protocol v12; authority: control. */
public final class SetColumnStickyRequest implements WireValue {
    private final Field<String> edge;
    private final Field<String> mode;
    private final UInt64 pane;
    private final boolean sticky;
    private final Field<UInt64> transaction;

    private SetColumnStickyRequest(Builder builder) {
        this.edge = builder.edge;
        this.mode = builder.mode;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.stickySet) throw new IllegalArgumentException("sticky is required");
        this.sticky = builder.sticky;
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> edge() { return edge; }
    public Field<String> mode() { return mode; }
    public UInt64 pane() { return pane; }
    public boolean sticky() { return sticky; }
    public Field<UInt64> transaction() { return transaction; }

    public static SetColumnStickyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetColumnStickyRequest");
        Builder builder = builder();
        Object rawEdge = Wire.optional(object, "edge");
        if (!Wire.isMissing(rawEdge)) {
            builder.edge(rawEdge == null ? null : Wire.string(rawEdge, "SetColumnStickyRequest.edge"));
        }
        Object rawMode = Wire.optional(object, "mode");
        if (!Wire.isMissing(rawMode)) {
            builder.mode(rawMode == null ? null : Wire.string(rawMode, "SetColumnStickyRequest.mode"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "SetColumnStickyRequest.pane"));
        Object rawSticky = Wire.required(object, "sticky");
        builder.sticky(Wire.bool(rawSticky, "SetColumnStickyRequest.sticky"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.uint64(rawTransaction, "SetColumnStickyRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "edge", edge);
        Wire.put(object, "mode", mode);
        Wire.put(object, "pane", pane);
        Wire.put(object, "sticky", sticky);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetColumnStickyRequest that)) return false;
        return Objects.equals(edge, that.edge) && Objects.equals(mode, that.mode) && Objects.equals(pane, that.pane) && Objects.equals(sticky, that.sticky) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(edge, mode, pane, sticky, transaction); }

    @Override
    public String toString() { return "SetColumnStickyRequest" + toWire(); }

    public static final class Builder {
        private Field<String> edge = Field.omitted();
        private Field<String> mode = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Boolean sticky;
        private boolean stickySet;
        private Field<UInt64> transaction = Field.omitted();

        public Builder edge(String value) {
            this.edge = Field.ofNullable(value);
            return this;
        }
        public Builder mode(String value) {
            this.mode = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder sticky(boolean value) {
            this.sticky = value;
            this.stickySet = true;
            return this;
        }
        public Builder transaction(UInt64 value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public SetColumnStickyRequest build() { return new SetColumnStickyRequest(this); }
    }
}
