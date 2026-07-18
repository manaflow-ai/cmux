package com.cmux;

import java.util.Map;
import java.util.UUID;

public record TopologySnapshot(
    UUID daemonInstanceId,
    UUID sessionId,
    long revision,
    CanonicalTopology topology
) {
    static TopologySnapshot from(Map<String, Object> map) {
        return new TopologySnapshot(
            TopologyWire.uuid(map.get("daemon_instance_id")),
            TopologyWire.uuid(map.get("session_id")),
            TopologyWire.uint(map.get("revision")),
            CanonicalTopology.from(map.get("topology"))
        );
    }

    public TopologyCursor cursor() {
        return new TopologyCursor(daemonInstanceId, sessionId, revision);
    }
}
