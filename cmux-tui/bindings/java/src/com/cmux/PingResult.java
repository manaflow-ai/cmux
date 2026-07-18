package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public record PingResult(
    boolean ok,
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
    Long pid
) {
    static PingResult from(Map<String, Object> data) {
        List<String> capabilities = new ArrayList<>();
        Object encodedCapabilities = data.get("capabilities");
        if (encodedCapabilities instanceof List<?> values) {
            for (Object value : values) capabilities.add(TopologyWire.string(value));
        }
        return new PingResult(
            Boolean.TRUE.equals(data.get("ok")),
            TopologyWire.string(data.get("version")),
            (int) TopologyWire.uint(data.get("protocol")),
            data.get("protocol_min") instanceof Number ? (int) TopologyWire.uint(data.get("protocol_min")) : null,
            data.get("protocol_max") instanceof Number ? (int) TopologyWire.uint(data.get("protocol_max")) : null,
            List.copyOf(capabilities),
            data.get("session") instanceof String ? TopologyWire.string(data.get("session")) : null,
            data.get("session_id") instanceof String ? TopologyWire.uuid(data.get("session_id")) : null,
            data.get("daemon_instance_id") instanceof String ? TopologyWire.uuid(data.get("daemon_instance_id")) : null,
            data.get("topology_revision") instanceof Number ? TopologyWire.uint(data.get("topology_revision")) : null,
            data.get("canonical_topology_revision") instanceof Number
                ? TopologyWire.uint(data.get("canonical_topology_revision"))
                : null,
            data.get("pid") instanceof Number ? TopologyWire.uint(data.get("pid")) : null
        );
    }
}
