// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public interface WorkspaceFirstTab extends WireValue {
    static WorkspaceFirstTab fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WorkspaceFirstTab");
        String tag = Wire.string(Wire.required(object, "kind"), "WorkspaceFirstTab.kind");
        return switch (tag) {
            case "browser" -> WorkspaceFirstTabBrowser.fromWire(value);
            default -> throw new CmuxDecodeException("unknown WorkspaceFirstTab tag " + tag, null);
        };
    }
}
