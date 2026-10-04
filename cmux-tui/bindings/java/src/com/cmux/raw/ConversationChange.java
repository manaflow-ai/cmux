// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public interface ConversationChange extends WireValue {
    static ConversationChange fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationChange");
        String tag = Wire.string(Wire.required(object, "kind"), "ConversationChange.kind");
        return switch (tag) {
            case "conversation" -> ConversationChangeConversation.fromWire(value);
            case "message" -> ConversationChangeMessage.fromWire(value);
            case "message-updated" -> ConversationChangeMessageUpdated.fromWire(value);
            case "read-cursor" -> ConversationChangeReadCursor.fromWire(value);
            default -> throw new CmuxDecodeException("unknown ConversationChange tag " + tag, null);
        };
    }
}
