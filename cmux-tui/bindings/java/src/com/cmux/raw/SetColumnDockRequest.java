// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-column-dock request. Protocol v12; authority: control. */
public final class SetColumnDockRequest implements WireValue {
    private final boolean dock;
    private final Field<String> edge;
    private final Field<String> mode;
    private final UInt64 pane;
    private final Field<Boolean> permanent;
    private final Field<String> role;
    private final Field<UInt64> transaction;

    private SetColumnDockRequest(Builder builder) {
        if (!builder.dockSet) throw new IllegalArgumentException("dock is required");
        this.dock = builder.dock;
        this.edge = builder.edge;
        this.mode = builder.mode;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.permanent = builder.permanent;
        this.role = builder.role;
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public boolean dock() { return dock; }
    public Field<String> edge() { return edge; }
    public Field<String> mode() { return mode; }
    public UInt64 pane() { return pane; }
    public Field<Boolean> permanent() { return permanent; }
    public Field<String> role() { return role; }
    public Field<UInt64> transaction() { return transaction; }

    public static SetColumnDockRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetColumnDockRequest");
        Builder builder = builder();
        Object rawDock = Wire.required(object, "dock");
        builder.dock(Wire.bool(rawDock, "SetColumnDockRequest.dock"));
        Object rawEdge = Wire.optional(object, "edge");
        if (!Wire.isMissing(rawEdge)) {
            builder.edge(rawEdge == null ? null : Wire.string(rawEdge, "SetColumnDockRequest.edge"));
        }
        Object rawMode = Wire.optional(object, "mode");
        if (!Wire.isMissing(rawMode)) {
            builder.mode(rawMode == null ? null : Wire.string(rawMode, "SetColumnDockRequest.mode"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "SetColumnDockRequest.pane"));
        Object rawPermanent = Wire.optional(object, "permanent");
        if (!Wire.isMissing(rawPermanent)) {
            builder.permanent(rawPermanent == null ? null : Wire.bool(rawPermanent, "SetColumnDockRequest.permanent"));
        }
        Object rawRole = Wire.optional(object, "role");
        if (!Wire.isMissing(rawRole)) {
            builder.role(rawRole == null ? null : Wire.string(rawRole, "SetColumnDockRequest.role"));
        }
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.uint64(rawTransaction, "SetColumnDockRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dock", dock);
        Wire.put(object, "edge", edge);
        Wire.put(object, "mode", mode);
        Wire.put(object, "pane", pane);
        Wire.put(object, "permanent", permanent);
        Wire.put(object, "role", role);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetColumnDockRequest that)) return false;
        return Objects.equals(dock, that.dock) && Objects.equals(edge, that.edge) && Objects.equals(mode, that.mode) && Objects.equals(pane, that.pane) && Objects.equals(permanent, that.permanent) && Objects.equals(role, that.role) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(dock, edge, mode, pane, permanent, role, transaction); }

    @Override
    public String toString() { return "SetColumnDockRequest" + toWire(); }

    public static final class Builder {
        private Boolean dock;
        private boolean dockSet;
        private Field<String> edge = Field.omitted();
        private Field<String> mode = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<Boolean> permanent = Field.omitted();
        private Field<String> role = Field.omitted();
        private Field<UInt64> transaction = Field.omitted();

        public Builder dock(boolean value) {
            this.dock = value;
            this.dockSet = true;
            return this;
        }
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
        public Builder permanent(Boolean value) {
            this.permanent = Field.ofNullable(value);
            return this;
        }
        public Builder role(String value) {
            this.role = Field.ofNullable(value);
            return this;
        }
        public Builder transaction(UInt64 value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public SetColumnDockRequest build() { return new SetColumnDockRequest(this); }
    }
}
