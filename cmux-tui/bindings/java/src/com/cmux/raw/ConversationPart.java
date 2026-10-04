// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public interface ConversationPart extends WireValue {
    static ConversationPart fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationPart");
        String tag = Wire.string(Wire.required(object, "type"), "ConversationPart.type");
        return switch (tag) {
            case "text" -> ConversationPartText.fromWire(value);
            case "work" -> ConversationPartWork.fromWire(value);
            default -> throw new CmuxDecodeException("unknown ConversationPart tag " + tag, null);
        };
    }
}
