package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public record CanonicalScreen(
    long id,
    UUID uuid,
    String name,
    CanonicalLayout layout,
    List<CanonicalPane> panes
) {
    @SuppressWarnings("unchecked")
    static CanonicalScreen from(Map<String, Object> map) {
        List<CanonicalPane> panes = new ArrayList<>();
        for (Object item : TopologyWire.list(map.get("panes"), "canonical panes")) {
            panes.add(CanonicalPane.from((Map<String, Object>) item));
        }
        return new CanonicalScreen(
            TopologyWire.uint(map.get("id")),
            TopologyWire.uuid(map.get("uuid")),
            TopologyWire.nullableString(map.get("name")),
            CanonicalLayout.from(map.get("layout")),
            List.copyOf(panes)
        );
    }
}
