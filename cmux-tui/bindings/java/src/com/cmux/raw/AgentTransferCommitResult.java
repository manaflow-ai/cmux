// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentTransferCommitResult implements WireValue {

    private AgentTransferCommitResult(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    public Boolean committed() { return true; }

    public static AgentTransferCommitResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferCommitResult");
        Builder builder = builder();
        Object rawCommitted = Wire.required(object, "committed");
        ProtocolSupport.literal(rawCommitted, true, "AgentTransferCommitResult.committed");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "committed", true);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferCommitResult that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "AgentTransferCommitResult" + toWire(); }

    public static final class Builder {

        public AgentTransferCommitResult build() { return new AgentTransferCommitResult(this); }
    }
}
