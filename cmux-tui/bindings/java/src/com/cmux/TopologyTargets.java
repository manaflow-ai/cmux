package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public record TopologyTargets(
    List<UUID> workspaces,
    List<UUID> screens,
    List<UUID> panes,
    List<UUID> surfaces
) {
    static TopologyTargets from(Object value) {
        Map<String, Object> map = TopologyWire.object(value, "topology targets");
        return new TopologyTargets(
            uuids(map.get("workspaces")), uuids(map.get("screens")),
            uuids(map.get("panes")), uuids(map.get("surfaces"))
        );
    }

    private static List<UUID> uuids(Object value) {
        if (value == null) return List.of();
        List<UUID> result = new ArrayList<>();
        for (Object item : TopologyWire.list(value, "UUID targets")) result.add(TopologyWire.uuid(item));
        return List.copyOf(result);
    }
}
