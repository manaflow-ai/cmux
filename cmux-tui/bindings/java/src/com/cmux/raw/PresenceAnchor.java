// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public interface PresenceAnchor extends WireValue {
    static PresenceAnchor fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PresenceAnchor");
        String tag = Wire.string(Wire.required(object, "kind"), "PresenceAnchor.kind");
        return switch (tag) {
            case "cell" -> PresenceAnchorCell.fromWire(value);
            case "point" -> PresenceAnchorPoint.fromWire(value);
            default -> throw new CmuxDecodeException("unknown PresenceAnchor tag " + tag, null);
        };
    }
}
