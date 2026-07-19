package com.cmux;

import java.util.Map;

public record IdentifyResult(
    String app,
    String version,
    int protocol,
    String session,
    long pid,
    String buildCommit,
    String ghosttyCommit
) {
    public IdentifyResult(String app, String version, int protocol, String session, long pid) {
        this(app, version, protocol, session, pid, null, null);
    }

    static IdentifyResult from(Map<String, Object> data) {
        return new IdentifyResult(
            CmuxClient.asString(data.get("app")),
            CmuxClient.asString(data.get("version")),
            (int) CmuxClient.asLong(data.get("protocol")),
            CmuxClient.asString(data.get("session")),
            CmuxClient.asLong(data.get("pid")),
            data.get("build_commit") == null ? null : CmuxClient.asString(data.get("build_commit")),
            data.get("ghostty_commit") == null ? null : CmuxClient.asString(data.get("ghostty_commit"))
        );
    }
}
