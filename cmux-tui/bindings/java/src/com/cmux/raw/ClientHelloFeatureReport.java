// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientHelloFeatureReport implements WireValue {
    private final List<String> applied;
    private final String hash;
    private final List<ClientHelloFeaturePending> pending;

    private ClientHelloFeatureReport(Builder builder) {
        if (!builder.appliedSet) throw new IllegalArgumentException("applied is required");
        this.applied = List.copyOf(Wire.nonNull(builder.applied, "applied"));
        if (!builder.hashSet) throw new IllegalArgumentException("hash is required");
        this.hash = Wire.nonNull(builder.hash, "hash");
        if (!builder.pendingSet) throw new IllegalArgumentException("pending is required");
        this.pending = List.copyOf(Wire.nonNull(builder.pending, "pending"));
    }

    public static Builder builder() { return new Builder(); }

    public List<String> applied() { return applied; }
    public String hash() { return hash; }
    public List<ClientHelloFeaturePending> pending() { return pending; }

    public static ClientHelloFeatureReport fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientHelloFeatureReport");
        Builder builder = builder();
        Object rawApplied = Wire.required(object, "applied");
        builder.applied(Wire.array(rawApplied, "ClientHelloFeatureReport.applied", item -> Wire.string(item, "ClientHelloFeatureReport.applied item")));
        Object rawHash = Wire.required(object, "hash");
        builder.hash(Wire.string(rawHash, "ClientHelloFeatureReport.hash"));
        Object rawPending = Wire.required(object, "pending");
        builder.pending(Wire.array(rawPending, "ClientHelloFeatureReport.pending", item -> ClientHelloFeaturePending.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "applied", applied);
        Wire.put(object, "hash", hash);
        Wire.put(object, "pending", pending);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientHelloFeatureReport that)) return false;
        return Objects.equals(applied, that.applied) && Objects.equals(hash, that.hash) && Objects.equals(pending, that.pending);
    }

    @Override
    public int hashCode() { return Objects.hash(applied, hash, pending); }

    @Override
    public String toString() { return "ClientHelloFeatureReport" + toWire(); }

    public static final class Builder {
        private List<String> applied;
        private boolean appliedSet;
        private String hash;
        private boolean hashSet;
        private List<ClientHelloFeaturePending> pending;
        private boolean pendingSet;

        public Builder applied(List<String> value) {
            this.applied = value;
            this.appliedSet = true;
            return this;
        }
        public Builder hash(String value) {
            this.hash = value;
            this.hashSet = true;
            return this;
        }
        public Builder pending(List<ClientHelloFeaturePending> value) {
            this.pending = value;
            this.pendingSet = true;
            return this;
        }
        public ClientHelloFeatureReport build() { return new ClientHelloFeatureReport(this); }
    }
}
