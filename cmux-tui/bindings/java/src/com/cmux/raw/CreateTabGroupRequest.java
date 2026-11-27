// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable create-tab-group request. Protocol v12; authority: control. */
public final class CreateTabGroupRequest implements WireValue {
    private final Field<String> color;
    private final Field<String> group;
    private final Field<String> name;
    private final List<Object> surfaces;
    private final Field<String> transaction;

    private CreateTabGroupRequest(Builder builder) {
        this.color = builder.color;
        this.group = builder.group;
        this.name = builder.name;
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> color() { return color; }
    public Field<String> group() { return group; }
    public Field<String> name() { return name; }
    public List<Object> surfaces() { return surfaces; }
    public Field<String> transaction() { return transaction; }

    public static CreateTabGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CreateTabGroupRequest");
        Builder builder = builder();
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "CreateTabGroupRequest.color"));
        }
        Object rawGroup = Wire.optional(object, "group");
        if (!Wire.isMissing(rawGroup)) {
            builder.group(rawGroup == null ? null : Wire.string(rawGroup, "CreateTabGroupRequest.group"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "CreateTabGroupRequest.name"));
        }
        Object rawSurfaces = Wire.required(object, "surfaces", "tabs");
        builder.surfaces(Wire.array(rawSurfaces, "CreateTabGroupRequest.surfaces", item -> Wire.immutableJson(item)));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "CreateTabGroupRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "color", color);
        Wire.put(object, "group", group);
        Wire.put(object, "name", name);
        Wire.put(object, "surfaces", surfaces);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CreateTabGroupRequest that)) return false;
        return Objects.equals(color, that.color) && Objects.equals(group, that.group) && Objects.equals(name, that.name) && Objects.equals(surfaces, that.surfaces) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(color, group, name, surfaces, transaction); }

    @Override
    public String toString() { return "CreateTabGroupRequest" + toWire(); }

    public static final class Builder {
        private Field<String> color = Field.omitted();
        private Field<String> group = Field.omitted();
        private Field<String> name = Field.omitted();
        private List<Object> surfaces;
        private boolean surfacesSet;
        private Field<String> transaction = Field.omitted();

        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder group(String value) {
            this.group = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
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
        public CreateTabGroupRequest build() { return new CreateTabGroupRequest(this); }
    }
}
