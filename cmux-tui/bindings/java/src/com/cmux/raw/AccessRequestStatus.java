// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public interface AccessRequestStatus extends WireValue {
    static AccessRequestStatus fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AccessRequestStatus");
        String tag = Wire.string(Wire.required(object, "state"), "AccessRequestStatus.state");
        return switch (tag) {
            case "delivered" -> AccessRequestStatusDelivered.fromWire(value);
            case "denied" -> AccessRequestStatusDenied.fromWire(value);
            case "pending" -> AccessRequestStatusPending.fromWire(value);
            default -> throw new CmuxDecodeException("unknown AccessRequestStatus tag " + tag, null);
        };
    }
}
