package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

public record IdentifyResult(
    String app,
    String version,
    int protocol,
    Integer protocolMin,
    Integer protocolMax,
    List<String> capabilities,
    String session,
    UUID sessionId,
    UUID daemonInstanceId,
    Long topologyRevision,
    Long canonicalTopologyRevision,
    long pid
) {
    public static final List<String> TOPOLOGY_V8_CAPABILITIES = List.of(
        "canonical-topology-snapshot-v1",
        "stable-entity-uuid-v1",
        "topology-resume-v1"
    );

    public IdentifyResult(String app, String version, int protocol, String session, long pid) {
        this(app, version, protocol, null, null, List.of(), session, null, null, null, null, pid);
    }

    static IdentifyResult from(Map<String, Object> data) {
        List<String> capabilities = new ArrayList<>();
        Object encodedCapabilities = data.get("capabilities");
        if (encodedCapabilities instanceof List<?> values) {
            for (Object value : values) capabilities.add(TopologyWire.string(value));
        }
        return new IdentifyResult(
            CmuxClient.asString(data.get("app")),
            CmuxClient.asString(data.get("version")),
            (int) CmuxClient.asLong(data.get("protocol")),
            data.get("protocol_min") instanceof Number ? (int) CmuxClient.asLong(data.get("protocol_min")) : null,
            data.get("protocol_max") instanceof Number ? (int) CmuxClient.asLong(data.get("protocol_max")) : null,
            List.copyOf(capabilities),
            CmuxClient.asString(data.get("session")),
            data.get("session_id") instanceof String ? TopologyWire.uuid(data.get("session_id")) : null,
            data.get("daemon_instance_id") instanceof String ? TopologyWire.uuid(data.get("daemon_instance_id")) : null,
            data.get("topology_revision") instanceof Number ? TopologyWire.uint(data.get("topology_revision")) : null,
            data.get("canonical_topology_revision") instanceof Number
                ? TopologyWire.uint(data.get("canonical_topology_revision"))
                : null,
            CmuxClient.asLong(data.get("pid"))
        );
    }

    public boolean supportsTopologyV8() {
        return protocol >= 8 && capabilities.containsAll(TOPOLOGY_V8_CAPABILITIES);
    }

    public Optional<TopologyCursor> topologyCursor() {
        if (daemonInstanceId == null || sessionId == null || canonicalTopologyRevision == null) {
            return Optional.empty();
        }
        return Optional.of(new TopologyCursor(daemonInstanceId, sessionId, canonicalTopologyRevision));
    }
}
