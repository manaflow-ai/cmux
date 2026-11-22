// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable helper-config request. Protocol v12; authority: local-admin. */
public final class HelperConfigRequest implements WireValue {
    private final Field<String> name;
    private final Field<HelperPermissions> permissions;

    private HelperConfigRequest(Builder builder) {
        this.name = builder.name;
        this.permissions = builder.permissions;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> name() { return name; }
    public Field<HelperPermissions> permissions() { return permissions; }

    public static HelperConfigRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HelperConfigRequest");
        Builder builder = builder();
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "HelperConfigRequest.name"));
        }
        Object rawPermissions = Wire.optional(object, "permissions");
        if (!Wire.isMissing(rawPermissions)) {
            builder.permissions(rawPermissions == null ? null : HelperPermissions.fromWire(rawPermissions));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "name", name);
        Wire.put(object, "permissions", permissions);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HelperConfigRequest that)) return false;
        return Objects.equals(name, that.name) && Objects.equals(permissions, that.permissions);
    }

    @Override
    public int hashCode() { return Objects.hash(name, permissions); }

    @Override
    public String toString() { return "HelperConfigRequest" + toWire(); }

    public static final class Builder {
        private Field<String> name = Field.omitted();
        private Field<HelperPermissions> permissions = Field.omitted();

        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder permissions(HelperPermissions value) {
            this.permissions = Field.ofNullable(value);
            return this;
        }
        public HelperConfigRequest build() { return new HelperConfigRequest(this); }
    }
}
