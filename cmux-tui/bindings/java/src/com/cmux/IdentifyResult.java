package com.cmux;

import java.util.Map;

public record IdentifyResult(String app, String version, int protocol, String session, long pid) {
    static IdentifyResult from(Map<String, Object> data) {
        return new IdentifyResult(
            CmuxClient.asString(data.get("app")),
            CmuxClient.asString(data.get("version")),
            (int) CmuxClient.asLong(data.get("protocol")),
            CmuxClient.asString(data.get("session")),
            CmuxClient.asLong(data.get("pid"))
        );
    }
}
