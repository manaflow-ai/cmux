// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Map;


public interface FsReadResult extends WireValue {
    static FsReadResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsReadResult");
        String tag = Wire.string(Wire.required(object, "encoding"), "FsReadResult.encoding");
        return switch (tag) {
            case "base64" -> FsReadResultBase64.fromWire(value);
            case "utf-8" -> FsReadResultUtf8.fromWire(value);
            default -> throw new CmuxDecodeException("unknown FsReadResult tag " + tag, null);
        };
    }
}
