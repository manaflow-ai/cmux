// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Map;

public record CommandMetadata(
    String wireName,
    Authority authority,
    int since,
    String capability,
    StreamKind streamKind,
    Map<String, Long> fieldSince,
    Map<String, String> fieldCapabilities
) {
    public CommandMetadata {
        fieldSince = Map.copyOf(fieldSince);
        fieldCapabilities = Map.copyOf(fieldCapabilities);
    }
}
