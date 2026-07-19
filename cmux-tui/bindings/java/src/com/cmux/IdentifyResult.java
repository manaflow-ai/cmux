package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record IdentifyResult(
    String app,
    String version,
    int protocol,
    String session,
    long pid,
    List<String> capabilities
) {
    public IdentifyResult(String app, String version, int protocol, String session, long pid) {
        this(app, version, protocol, session, pid, List.of());
    }

    static IdentifyResult from(Map<String, Object> data) {
        return new IdentifyResult(
            CmuxClient.asString(data.get("app")),
            CmuxClient.asString(data.get("version")),
            (int) CmuxClient.asLong(data.get("protocol")),
            CmuxClient.asString(data.get("session")),
            CmuxClient.asLong(data.get("pid")),
            capabilities(data.get("capabilities"))
        );
    }

    private static List<String> capabilities(Object value) {
        if (!(value instanceof List<?> values)) {
            return List.of();
        }
        List<String> capabilities = new ArrayList<>(values.size());
        for (Object item : values) {
            capabilities.add(CmuxClient.asString(item));
        }
        return List.copyOf(capabilities);
    }
}
