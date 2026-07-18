package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record CanonicalTopology(List<CanonicalWorkspace> workspaces) {
    @SuppressWarnings("unchecked")
    static CanonicalTopology from(Object value) {
        Map<String, Object> map = TopologyWire.object(value, "canonical topology");
        List<CanonicalWorkspace> workspaces = new ArrayList<>();
        for (Object item : TopologyWire.list(map.get("workspaces"), "canonical workspaces")) {
            workspaces.add(CanonicalWorkspace.from((Map<String, Object>) item));
        }
        return new CanonicalTopology(List.copyOf(workspaces));
    }
}
