package com.cmux;

import java.util.Map;
import java.util.UUID;

public record TopologyResnapshotRequired(
    UUID daemonInstanceId,
    UUID sessionId,
    Long currentRevision,
    TopologyResnapshotReason reason
) implements TopologyStreamEvent, TopologySubscribeOutcome {
    static TopologyResnapshotRequired from(Map<String, Object> map) {
        Object current = map.get("current_revision");
        return new TopologyResnapshotRequired(
            TopologyWire.uuid(map.get("daemon_instance_id")),
            TopologyWire.uuid(map.get("session_id")),
            current == null ? null : TopologyWire.uint(current),
            TopologyResnapshotReason.from(TopologyWire.string(map.get("reason")))
        );
    }

    @Override public String event() { return "topology-resnapshot-required"; }
}
