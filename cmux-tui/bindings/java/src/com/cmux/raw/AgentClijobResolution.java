// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public interface AgentClijobResolution extends WireValue {
    static AgentClijobResolution fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClijobResolution");
        String tag = Wire.string(Wire.required(object, "state"), "AgentClijobResolution.state");
        return switch (tag) {
            case "created" -> AgentClijobResolutionCreated.fromWire(value);
            case "failed" -> AgentClijobResolutionFailed.fromWire(value);
            case "indeterminate" -> AgentClijobResolutionIndeterminate.fromWire(value);
            case "not_found" -> AgentClijobResolutionNotFound.fromWire(value);
            case "pending" -> AgentClijobResolutionPending.fromWire(value);
            case "prepared" -> AgentClijobResolutionPrepared.fromWire(value);
            default -> throw new CmuxDecodeException("unknown AgentClijobResolution tag " + tag, null);
        };
    }
}
