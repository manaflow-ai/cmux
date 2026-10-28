// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BridgeHelloResult implements WireValue {
    private final List<String> features;

    private BridgeHelloResult(Builder builder) {
        if (!builder.featuresSet) throw new IllegalArgumentException("features is required");
        this.features = List.copyOf(Wire.nonNull(builder.features, "features"));
    }

    public static Builder builder() { return new Builder(); }

    public List<String> features() { return features; }

    public static BridgeHelloResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BridgeHelloResult");
        Builder builder = builder();
        Object rawFeatures = Wire.required(object, "features");
        builder.features(Wire.array(rawFeatures, "BridgeHelloResult.features", item -> Wire.string(item, "BridgeHelloResult.features item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "features", features);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BridgeHelloResult that)) return false;
        return Objects.equals(features, that.features);
    }

    @Override
    public int hashCode() { return Objects.hash(features); }

    @Override
    public String toString() { return "BridgeHelloResult" + toWire(); }

    public static final class Builder {
        private List<String> features;
        private boolean featuresSet;

        public Builder features(List<String> value) {
            this.features = value;
            this.featuresSet = true;
            return this;
        }
        public BridgeHelloResult build() { return new BridgeHelloResult(this); }
    }
}
