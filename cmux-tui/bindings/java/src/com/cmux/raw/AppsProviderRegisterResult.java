// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppsProviderRegisterResult implements WireValue {
    private final List<String> families;
    private final Field<AppsInventoryDemand> inventoryDemand;

    private AppsProviderRegisterResult(Builder builder) {
        if (!builder.familiesSet) throw new IllegalArgumentException("families is required");
        this.families = List.copyOf(Wire.nonNull(builder.families, "families"));
        this.inventoryDemand = builder.inventoryDemand;
    }

    public static Builder builder() { return new Builder(); }

    public List<String> families() { return families; }
    public Field<AppsInventoryDemand> inventoryDemand() { return inventoryDemand; }

    public static AppsProviderRegisterResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsProviderRegisterResult");
        Builder builder = builder();
        Object rawFamilies = Wire.required(object, "families");
        builder.families(Wire.array(rawFamilies, "AppsProviderRegisterResult.families", item -> Wire.string(item, "AppsProviderRegisterResult.families item")));
        Object rawInventoryDemand = Wire.optional(object, "inventory_demand");
        if (!Wire.isMissing(rawInventoryDemand)) {
            builder.inventoryDemand(AppsInventoryDemand.fromWire(rawInventoryDemand));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "families", families);
        Wire.put(object, "inventory_demand", inventoryDemand);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsProviderRegisterResult that)) return false;
        return Objects.equals(families, that.families) && Objects.equals(inventoryDemand, that.inventoryDemand);
    }

    @Override
    public int hashCode() { return Objects.hash(families, inventoryDemand); }

    @Override
    public String toString() { return "AppsProviderRegisterResult" + toWire(); }

    public static final class Builder {
        private List<String> families;
        private boolean familiesSet;
        private Field<AppsInventoryDemand> inventoryDemand = Field.omitted();

        public Builder families(List<String> value) {
            this.families = value;
            this.familiesSet = true;
            return this;
        }
        public Builder inventoryDemand(AppsInventoryDemand value) {
            this.inventoryDemand = Field.of(value);
            return this;
        }
        public AppsProviderRegisterResult build() { return new AppsProviderRegisterResult(this); }
    }
}
