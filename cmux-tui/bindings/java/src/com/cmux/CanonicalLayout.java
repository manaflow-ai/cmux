package com.cmux;

import java.util.Map;
import java.util.UUID;

public sealed interface CanonicalLayout permits CanonicalLayout.Leaf, CanonicalLayout.Split {
    record Leaf(long pane, UUID paneUuid) implements CanonicalLayout {}
    record Split(String dir, double ratio, CanonicalLayout a, CanonicalLayout b) implements CanonicalLayout {}

    static CanonicalLayout from(Object value) {
        Map<String, Object> map = TopologyWire.object(value, "canonical layout");
        String type = TopologyWire.string(map.get("type"));
        if ("leaf".equals(type)) {
            return new Leaf(TopologyWire.uint(map.get("pane")), TopologyWire.uuid(map.get("pane_uuid")));
        }
        if ("split".equals(type)) {
            String dir = TopologyWire.string(map.get("dir"));
            if (!"right".equals(dir) && !"down".equals(dir)) {
                throw new IllegalArgumentException("invalid canonical split direction " + dir);
            }
            return new Split(
                dir,
                TopologyWire.number(map.get("ratio")),
                from(map.get("a")),
                from(map.get("b"))
            );
        }
        throw new IllegalArgumentException("invalid canonical layout type " + type);
    }
}
