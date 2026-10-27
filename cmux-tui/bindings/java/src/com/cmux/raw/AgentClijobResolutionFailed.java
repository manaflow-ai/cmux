// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentClijobResolutionFailed implements WireValue, AgentClijobResolution {
    private final String code;

    private AgentClijobResolutionFailed(Builder builder) {
        if (!builder.codeSet) throw new IllegalArgumentException("code is required");
        this.code = Wire.nonNull(builder.code, "code");
    }

    public static Builder builder() { return new Builder(); }

    public String code() { return code; }
    public String state() { return "failed"; }

    public static AgentClijobResolutionFailed fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClijobResolutionFailed");
        Builder builder = builder();
        Object rawCode = Wire.required(object, "code");
        builder.code(Wire.string(rawCode, "AgentClijobResolutionFailed.code"));
        Object rawState = Wire.required(object, "state");
        ProtocolSupport.literal(rawState, "failed", "AgentClijobResolutionFailed.state");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "code", code);
        Wire.put(object, "state", "failed");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentClijobResolutionFailed that)) return false;
        return Objects.equals(code, that.code);
    }

    @Override
    public int hashCode() { return Objects.hash(code); }

    @Override
    public String toString() { return "AgentClijobResolutionFailed" + toWire(); }

    public static final class Builder {
        private String code;
        private boolean codeSet;

        public Builder code(String value) {
            this.code = value;
            this.codeSet = true;
            return this;
        }
        public AgentClijobResolutionFailed build() { return new AgentClijobResolutionFailed(this); }
    }
}
