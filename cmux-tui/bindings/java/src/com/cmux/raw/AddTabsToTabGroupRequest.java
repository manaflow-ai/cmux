// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable add-tabs-to-tab-group request. Protocol v12; authority: control. */
public final class AddTabsToTabGroupRequest implements WireValue {
    private final String group;
    private final List<Object> surfaces;
    private final Field<String> transaction;

    private AddTabsToTabGroupRequest(Builder builder) {
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public String group() { return group; }
    public List<Object> surfaces() { return surfaces; }
    public Field<String> transaction() { return transaction; }

    public static AddTabsToTabGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AddTabsToTabGroupRequest");
        Builder builder = builder();
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "AddTabsToTabGroupRequest.group"));
        Object rawSurfaces = Wire.required(object, "surfaces", "tabs");
        builder.surfaces(Wire.array(rawSurfaces, "AddTabsToTabGroupRequest.surfaces", item -> Wire.immutableJson(item)));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "AddTabsToTabGroupRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "group", group);
        Wire.put(object, "surfaces", surfaces);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AddTabsToTabGroupRequest that)) return false;
        return Objects.equals(group, that.group) && Objects.equals(surfaces, that.surfaces) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(group, surfaces, transaction); }

    @Override
    public String toString() { return "AddTabsToTabGroupRequest" + toWire(); }

    public static final class Builder {
        private String group;
        private boolean groupSet;
        private List<Object> surfaces;
        private boolean surfacesSet;
        private Field<String> transaction = Field.omitted();

        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder surfaces(List<Object> value) {
            this.surfaces = value;
            this.surfacesSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public AddTabsToTabGroupRequest build() { return new AddTabsToTabGroupRequest(this); }
    }
}
