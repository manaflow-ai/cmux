// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-size-policy request. Protocol v12; authority: control. */
public final class SetSizePolicyRequest implements WireValue {
    private final Field<SizePolicy> policy;
    private final Field<UInt64> surface;
    private final Field<UInt64> workspace;

    private SetSizePolicyRequest(Builder builder) {
        this.policy = builder.policy;
        this.surface = builder.surface;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<SizePolicy> policy() { return policy; }
    public Field<UInt64> surface() { return surface; }
    public Field<UInt64> workspace() { return workspace; }

    public static SetSizePolicyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetSizePolicyRequest");
        Builder builder = builder();
        Object rawPolicy = Wire.optional(object, "policy");
        if (!Wire.isMissing(rawPolicy)) {
            builder.policy(rawPolicy == null ? null : SizePolicy.fromWire(rawPolicy));
        }
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "SetSizePolicyRequest.surface"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "SetSizePolicyRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "policy", policy);
        Wire.put(object, "surface", surface);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetSizePolicyRequest that)) return false;
        return Objects.equals(policy, that.policy) && Objects.equals(surface, that.surface) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(policy, surface, workspace); }

    @Override
    public String toString() { return "SetSizePolicyRequest" + toWire(); }

    public static final class Builder {
        private Field<SizePolicy> policy = Field.omitted();
        private Field<UInt64> surface = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder policy(SizePolicy value) {
            this.policy = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public SetSizePolicyRequest build() { return new SetSizePolicyRequest(this); }
    }
}
