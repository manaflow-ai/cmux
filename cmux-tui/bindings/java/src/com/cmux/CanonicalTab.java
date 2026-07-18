package com.cmux;

import java.util.Map;
import java.util.UUID;

public record CanonicalTab(long id, UUID uuid, String kind, String name) {
    static CanonicalTab from(Map<String, Object> map) {
        String kind = TopologyWire.string(map.get("kind"));
        if (!"pty".equals(kind) && !"browser".equals(kind)) {
            throw new IllegalArgumentException("invalid canonical tab kind " + kind);
        }
        return new CanonicalTab(
            TopologyWire.uint(map.get("id")),
            TopologyWire.uuid(map.get("uuid")),
            kind,
            TopologyWire.nullableString(map.get("name"))
        );
    }
}
