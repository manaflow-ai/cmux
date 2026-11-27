// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-group request. Protocol v12; authority: control. */
public final class MoveTabGroupRequest implements WireValue {
    private final String group;
    private final Field<UInt64> index;
    private final Field<Object> pane;
    private final Field<String> transaction;

    private MoveTabGroupRequest(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        this.index = builder.index;
        this.pane = builder.pane;
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }
    public Field<UInt64> index() { return index; }
    public Field<Object> pane() { return pane; }
    public Field<String> transaction() { return transaction; }

    public static MoveTabGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabGroupRequest");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "MoveTabGroupRequest.group"));
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "MoveTabGroupRequest.index"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.immutableJson(rawPane));
        }
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "MoveTabGroupRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "index", index);
        Wire.put(object, "pane", pane);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabGroupRequest that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(index, that.index) && Objects.equals(pane, that.pane) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(group, index, pane, transaction); }

    @Override
    public String toString() { return "MoveTabGroupRequest" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;
        private Field<UInt64> index = Field.omitted();
        private Field<Object> pane = Field.omitted();
        private Field<String> transaction = Field.omitted();

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder pane(Object value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public MoveTabGroupRequest build() { return new MoveTabGroupRequest(this); }
    }
}
