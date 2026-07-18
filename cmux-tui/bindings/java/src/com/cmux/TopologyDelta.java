package com.cmux;

import java.util.Map;
import java.util.UUID;

public record TopologyDelta(
    UUID daemonInstanceId,
    UUID sessionId,
    long baseRevision,
    long revision,
    TopologyOperation operation,
    TopologyTargets targets,
    CanonicalTopology replacement
) implements TopologyStreamEvent {
    static TopologyDelta from(Map<String, Object> map) {
        return new TopologyDelta(
            TopologyWire.uuid(map.get("daemon_instance_id")),
            TopologyWire.uuid(map.get("session_id")),
            TopologyWire.uint(map.get("base_revision")),
            TopologyWire.uint(map.get("revision")),
            TopologyOperation.from(TopologyWire.string(map.get("operation"))),
            TopologyTargets.from(map.get("targets")),
            CanonicalTopology.from(map.get("replacement"))
        );
    }

    @Override public String event() { return "topology-delta"; }
}
