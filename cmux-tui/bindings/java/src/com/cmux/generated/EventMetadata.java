// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.generated;

import java.util.List;

public record EventMetadata(
    String wireName,
    int since,
    String capability,
    List<String> streams,
    boolean emitted
) {
    public EventMetadata { streams = List.copyOf(streams); }
}
