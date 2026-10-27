// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentTransferAbortResult implements WireValue {

    private AgentTransferAbortResult(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    public Boolean aborted() { return true; }

    public static AgentTransferAbortResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferAbortResult");
        Builder builder = builder();
        Object rawAborted = Wire.required(object, "aborted");
        ProtocolSupport.literal(rawAborted, true, "AgentTransferAbortResult.aborted");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "aborted", true);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferAbortResult that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "AgentTransferAbortResult" + toWire(); }

    public static final class Builder {

        public AgentTransferAbortResult build() { return new AgentTransferAbortResult(this); }
    }
}
