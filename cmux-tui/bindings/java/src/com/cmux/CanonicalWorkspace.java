package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public record CanonicalWorkspace(long id, UUID uuid, String name, List<CanonicalScreen> screens) {
    @SuppressWarnings("unchecked")
    static CanonicalWorkspace from(Map<String, Object> map) {
        List<CanonicalScreen> screens = new ArrayList<>();
        for (Object item : TopologyWire.list(map.get("screens"), "canonical screens")) {
            screens.add(CanonicalScreen.from((Map<String, Object>) item));
        }
        return new CanonicalWorkspace(
            TopologyWire.uint(map.get("id")),
            TopologyWire.uuid(map.get("uuid")),
            TopologyWire.string(map.get("name")),
            List.copyOf(screens)
        );
    }
}
