package com.cmux;

import java.util.Map;
import java.util.UUID;

public record TopologySubscribed(
    UUID daemonInstanceId,
    UUID sessionId,
    long fromRevision,
    long currentRevision,
    long replayed
) {
    static TopologySubscribed from(Map<String, Object> map) {
        return new TopologySubscribed(
            TopologyWire.uuid(map.get("daemon_instance_id")),
            TopologyWire.uuid(map.get("session_id")),
            TopologyWire.uint(map.get("from_revision")),
            TopologyWire.uint(map.get("current_revision")),
            TopologyWire.uint(map.get("replayed"))
        );
    }
}
