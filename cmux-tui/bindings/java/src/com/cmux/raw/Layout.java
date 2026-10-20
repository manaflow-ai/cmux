// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public interface Layout extends WireValue {
    static Layout fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Layout");
        String tag = Wire.string(Wire.required(object, "type"), "Layout.type");
        return switch (tag) {
            case "leaf" -> LayoutLeaf.fromWire(value);
            case "split" -> LayoutSplit.fromWire(value);
            case "stack" -> LayoutStack.fromWire(value);
            default -> throw new CmuxDecodeException("unknown Layout tag " + tag, null);
        };
    }
}
