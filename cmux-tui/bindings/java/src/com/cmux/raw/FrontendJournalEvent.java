// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public interface FrontendJournalEvent extends WireValue {
    static FrontendJournalEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendJournalEvent");
        String tag = Wire.string(Wire.required(object, "kind"), "FrontendJournalEvent.kind");
        return switch (tag) {
            case "focus" -> FrontendJournalEventFocus.fromWire(value);
            case "resize" -> FrontendJournalEventResize.fromWire(value);
            case "viewport" -> FrontendJournalEventViewport.fromWire(value);
            default -> throw new CmuxDecodeException("unknown FrontendJournalEvent tag " + tag, null);
        };
    }
}
