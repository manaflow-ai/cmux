// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable remove-tabs-from-tab-group request. Protocol v12; authority: control. */
public final class RemoveTabsFromTabGroupRequest implements WireValue {
    private final List<Object> surfaces;
    private final Field<String> transaction;

    private RemoveTabsFromTabGroupRequest(Builder builder) {
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public List<Object> surfaces() { return surfaces; }
    public Field<String> transaction() { return transaction; }

    public static RemoveTabsFromTabGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RemoveTabsFromTabGroupRequest");
        Builder builder = builder();
        Object rawSurfaces = Wire.required(object, "surfaces", "tabs");
        builder.surfaces(Wire.array(rawSurfaces, "RemoveTabsFromTabGroupRequest.surfaces", item -> Wire.immutableJson(item)));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "RemoveTabsFromTabGroupRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surfaces", surfaces);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RemoveTabsFromTabGroupRequest that)) return false;
        return Objects.equals(surfaces, that.surfaces) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(surfaces, transaction); }

    @Override
    public String toString() { return "RemoveTabsFromTabGroupRequest" + toWire(); }

    public static final class Builder {
        private List<Object> surfaces;
        private boolean surfacesSet;
        private Field<String> transaction = Field.omitted();

        public Builder surfaces(List<Object> value) {
            this.surfaces = value;
            this.surfacesSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public RemoveTabsFromTabGroupRequest build() { return new RemoveTabsFromTabGroupRequest(this); }
    }
}
