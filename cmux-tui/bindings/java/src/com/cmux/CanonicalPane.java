package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public record CanonicalPane(long id, UUID uuid, String name, List<CanonicalTab> tabs) {
    @SuppressWarnings("unchecked")
    static CanonicalPane from(Map<String, Object> map) {
        List<CanonicalTab> tabs = new ArrayList<>();
        for (Object item : TopologyWire.list(map.get("tabs"), "canonical tabs")) {
            tabs.add(CanonicalTab.from((Map<String, Object>) item));
        }
        return new CanonicalPane(
            TopologyWire.uint(map.get("id")),
            TopologyWire.uuid(map.get("uuid")),
            TopologyWire.nullableString(map.get("name")),
            List.copyOf(tabs)
        );
    }
}
