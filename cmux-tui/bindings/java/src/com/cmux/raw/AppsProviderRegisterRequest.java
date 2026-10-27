// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-provider-register request. Protocol v12; authority: local-admin. */
public final class AppsProviderRegisterRequest implements WireValue {
    private final List<String> families;
    private final Field<Boolean> inventoryWatch;
    private final Field<AppOrigin> origin;

    private AppsProviderRegisterRequest(Builder builder) {
        if (!builder.familiesSet) throw new IllegalArgumentException("families is required");
        this.families = List.copyOf(Wire.nonNull(builder.families, "families"));
        this.inventoryWatch = builder.inventoryWatch;
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public List<String> families() { return families; }
    public Field<Boolean> inventoryWatch() { return inventoryWatch; }
    public Field<AppOrigin> origin() { return origin; }

    public static AppsProviderRegisterRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsProviderRegisterRequest");
        Builder builder = builder();
        Object rawFamilies = Wire.required(object, "families");
        builder.families(Wire.array(rawFamilies, "AppsProviderRegisterRequest.families", item -> Wire.string(item, "AppsProviderRegisterRequest.families item")));
        Object rawInventoryWatch = Wire.optional(object, "inventory_watch");
        if (!Wire.isMissing(rawInventoryWatch)) {
            builder.inventoryWatch(Wire.bool(rawInventoryWatch, "AppsProviderRegisterRequest.inventory_watch"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "families", families);
        Wire.put(object, "inventory_watch", inventoryWatch);
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsProviderRegisterRequest that)) return false;
        return Objects.equals(families, that.families) && Objects.equals(inventoryWatch, that.inventoryWatch) && Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(families, inventoryWatch, origin); }

    @Override
    public String toString() { return "AppsProviderRegisterRequest" + toWire(); }

    public static final class Builder {
        private List<String> families;
        private boolean familiesSet;
        private Field<Boolean> inventoryWatch = Field.omitted();
        private Field<AppOrigin> origin = Field.omitted();

        public Builder families(List<String> value) {
            this.families = value;
            this.familiesSet = true;
            return this;
        }
        public Builder inventoryWatch(Boolean value) {
            this.inventoryWatch = Field.of(value);
            return this;
        }
        public Builder origin(AppOrigin value) {
            this.origin = Field.of(value);
            return this;
        }
        public AppsProviderRegisterRequest build() { return new AppsProviderRegisterRequest(this); }
    }
}
