// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-host-replica-status request. Protocol v12; authority: local-admin. */
public final class CloudHostReplicaStatusRequest implements WireValue {

    private CloudHostReplicaStatusRequest(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }


    public static CloudHostReplicaStatusRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudHostReplicaStatusRequest");
        Builder builder = builder();
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudHostReplicaStatusRequest that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "CloudHostReplicaStatusRequest" + toWire(); }

    public static final class Builder {

        public CloudHostReplicaStatusRequest build() { return new CloudHostReplicaStatusRequest(this); }
    }
}
