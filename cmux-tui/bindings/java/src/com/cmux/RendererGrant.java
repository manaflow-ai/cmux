package com.cmux;

import java.util.List;
import java.util.Objects;

public record RendererGrant(
    String endpoint,
    Ids.TerminalId terminalId,
    Secret token,
    List<String> rights,
    int ttlMillis
) {
    public RendererGrant {
        Objects.requireNonNull(endpoint, "endpoint");
        Objects.requireNonNull(terminalId, "terminalId");
        Objects.requireNonNull(token, "token");
        rights = List.copyOf(rights);
        if (ttlMillis < 1 || ttlMillis > 60_000) {
            throw new IllegalArgumentException("ttlMillis must be between 1 and 60000");
        }
    }

    @Override
    public String toString() {
        return "RendererGrant[endpoint=" + endpoint +
            ", terminalId=" + terminalId +
            ", token=<redacted>, rights=" + rights +
            ", ttlMillis=" + ttlMillis + "]";
    }
}
