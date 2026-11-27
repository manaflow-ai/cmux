// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-host-replica-clear request. Protocol v12; authority: local-admin. */
public final class CloudHostReplicaClearRequest implements WireValue {
    private final Field<Boolean> purge;

    private CloudHostReplicaClearRequest(Builder builder) {
        this.purge = builder.purge;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> purge() { return purge; }

    public static CloudHostReplicaClearRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudHostReplicaClearRequest");
        Builder builder = builder();
        Object rawPurge = Wire.optional(object, "purge");
        if (!Wire.isMissing(rawPurge)) {
            builder.purge(Wire.bool(rawPurge, "CloudHostReplicaClearRequest.purge"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "purge", purge);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudHostReplicaClearRequest that)) return false;
        return Objects.equals(purge, that.purge);
    }

    @Override
    public int hashCode() { return Objects.hash(purge); }

    @Override
    public String toString() { return "CloudHostReplicaClearRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> purge = Field.omitted();

        public Builder purge(Boolean value) {
            this.purge = Field.of(value);
            return this;
        }
        public CloudHostReplicaClearRequest build() { return new CloudHostReplicaClearRequest(this); }
    }
}
