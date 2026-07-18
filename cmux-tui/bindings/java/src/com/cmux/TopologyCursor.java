package com.cmux;

import java.util.UUID;

public record TopologyCursor(UUID daemonInstanceId, UUID sessionId, long revision) {
    public TopologyCursor {
        if (daemonInstanceId == null || sessionId == null || revision < 0) {
            throw new IllegalArgumentException("topology cursor requires UUID authority and non-negative revision");
        }
    }

    public TopologyAuthority authority() {
        return new TopologyAuthority(daemonInstanceId, sessionId);
    }
}
