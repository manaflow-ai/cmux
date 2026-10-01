// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-to-new-workspace request. Protocol v12; authority: control. */
public final class MoveTabToNewWorkspaceRequest implements WireValue {
    private final Field<String> group;
    private final Field<UInt64> index;
    private final UInt64 surface;
    private final Field<String> transaction;

    private MoveTabToNewWorkspaceRequest(Builder builder) {
        this.group = builder.group;
        this.index = builder.index;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> group() { return group; }
    public Field<UInt64> index() { return index; }
    public UInt64 surface() { return surface; }
    public Field<String> transaction() { return transaction; }

    public static MoveTabToNewWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabToNewWorkspaceRequest");
        Builder builder = builder();
        Object rawGroup = Wire.optional(object, "group");
        if (!Wire.isMissing(rawGroup)) {
            builder.group(rawGroup == null ? null : Wire.string(rawGroup, "MoveTabToNewWorkspaceRequest.group"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "MoveTabToNewWorkspaceRequest.index"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "MoveTabToNewWorkspaceRequest.surface"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "MoveTabToNewWorkspaceRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "index", index);
        Wire.put(object, "surface", surface);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabToNewWorkspaceRequest that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(index, that.index) && Objects.equals(surface, that.surface) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(group, index, surface, transaction); }

    @Override
    public String toString() { return "MoveTabToNewWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private Field<String> group = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> transaction = Field.omitted();

        public Builder group(String value) {
            this.group = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
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
        public MoveTabToNewWorkspaceRequest build() { return new MoveTabToNewWorkspaceRequest(this); }
    }
}
