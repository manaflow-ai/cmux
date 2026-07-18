package com.cmux;

import java.util.UUID;

public record TopologyAuthority(UUID daemonInstanceId, UUID sessionId) {}
