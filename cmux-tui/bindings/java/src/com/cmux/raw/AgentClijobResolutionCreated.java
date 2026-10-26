// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentClijobResolutionCreated implements WireValue, AgentClijobResolution {
    private final AgentCLIJobReceipt receipt;

    private AgentClijobResolutionCreated(Builder builder) {
        if (!builder.receiptSet) throw new IllegalArgumentException("receipt is required");
        this.receipt = Wire.nonNull(builder.receipt, "receipt");
    }

    public static Builder builder() { return new Builder(); }

    public AgentCLIJobReceipt receipt() { return receipt; }
    public String state() { return "created"; }

    public static AgentClijobResolutionCreated fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClijobResolutionCreated");
        Builder builder = builder();
        Object rawReceipt = Wire.required(object, "receipt");
        builder.receipt(AgentCLIJobReceipt.fromWire(rawReceipt));
        Object rawState = Wire.required(object, "state");
        ProtocolSupport.literal(rawState, "created", "AgentClijobResolutionCreated.state");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "receipt", receipt);
        Wire.put(object, "state", "created");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentClijobResolutionCreated that)) return false;
        return Objects.equals(receipt, that.receipt);
    }

    @Override
    public int hashCode() { return Objects.hash(receipt); }

    @Override
    public String toString() { return "AgentClijobResolutionCreated" + toWire(); }

    public static final class Builder {
        private AgentCLIJobReceipt receipt;
        private boolean receiptSet;

        public Builder receipt(AgentCLIJobReceipt value) {
            this.receipt = value;
            this.receiptSet = true;
            return this;
        }
        public AgentClijobResolutionCreated build() { return new AgentClijobResolutionCreated(this); }
    }
}
